// Standing check: lwt-monthly is the only door from the Monthly Report page to the bot, and it opens only what it should.
//
//   node scripts/checks/lwt_monthly_edge.mjs
//
// Runs the function offline (esbuild strips the imports; stubs replace createClient, the staff and access checks,
// Deno.env/serve and fetch, which plays the bot and PostgREST). Then the same scenarios run against copies with a guard
// removed: each copy must FAIL, because a check that cannot fail proves nothing. Exit 0 = all hold.
// Why: Trello EOnFKqSK, spec Building Apps/DERM Tracker/docs/specs/2026-11-05-monthly-report-in-the-app.md.
// Needs node + npx esbuild@0.24.0.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { pathToFileURL, fileURLToPath } from 'node:url'

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const FN = 'supabase/functions/lwt-monthly/index.ts'
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'lwt-monthly-'))

fs.writeFileSync(path.join(TMP, 'stub.mjs'), [
  'export function createClient(_u, key) { return key === "anon" ? globalThis.__user : globalThis.__sb }',
  'export const isStaffEmail = async () => globalThis.__staff !== false',
  'export const checkAppAction = async (_t, a) => (globalThis.__deny ?? {})[a] ?? null',
].join('\n'))
const IMPORTS = [
  "import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'",
  "import { isStaffEmail } from '../_shared/staff.ts'",
  "import { checkAppAction } from '../_shared/access-check.ts'",
]
const esbuild = (ts, out) => execFileSync(process.platform === 'win32' ? 'npx.cmd' : 'npx', ['--no-install', 'esbuild@0.24.0', ts, '--format=esm', `--outfile=${out}`, '--log-level=error'], { shell: process.platform === 'win32', cwd: REPO })
function build(name, src) {
  for (const line of IMPORTS) {
    if (!src.includes(line)) throw new Error(`${name}: an import line changed, update this check`)
    src = src.replace(line, line.replace(/from '.*'/, "from './stub.mjs'"))
  }
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
const ON = { SUPABASE_URL: 'http://db', SUPABASE_SERVICE_ROLE_KEY: 'service', SUPABASE_ANON_KEY: 'anon', GDO_BOT_FILE_URL: 'https://bot.example/gdo/process-one', GDO_BOT_FILE_KEY: 'k-derm' }
const OFF = { SUPABASE_URL: 'http://db', SUPABASE_SERVICE_ROLE_KEY: 'service', SUPABASE_ANON_KEY: 'anon' }
const EDIT = 'lwt_monthly_edit', VIEW = 'lwt_monthly_view'

function world({ staff = true, deny = {}, bot = null, botThrows = false, signedIn = true, work = null, workErr = null } = {}) {
  const w = { botCalls: [], rpcCalls: [], uploads: [] }
  globalThis.__staff = staff
  globalThis.__deny = deny
  globalThis.__user = { auth: { getUser: async () => signedIn ? { data: { user: { email: 'person@unclogme.com' } }, error: null } : { data: {}, error: { message: 'no' } } } }
  const chain = { select: () => chain, ilike: () => chain, limit: async () => ({ data: [{ full_name: 'Diego Ramos' }], error: null }) }
  globalThis.__sb = {
    from: () => chain,
    storage: { from: (b) => ({
      download: async (p) => { w.download = { b, p }; return work === null ? { data: null, error: workErr ?? { message: 'Object not found', status: 404 } } : { data: { text: async () => JSON.stringify(work) }, error: null } },
      upload: async (p, blob, o) => { w.uploads.push({ b, p, o, text: await blob.text() }); return { error: workErr } },
    }) },
  }
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url)
    if (u.startsWith('http://db/rest/v1/rpc/')) {
      w.rpcCalls.push({ url: u, init, args: JSON.parse(init.body) })
      return new Response(JSON.stringify(w.rpcAnswer ?? { ok: true }), { status: w.rpcStatus ?? 200 })
    }
    w.botCalls.push({ url: u, init })
    if (botThrows) throw new DOMException('timed out', 'TimeoutError')
    const b = bot ?? { status: 200, body: { ok: true } }
    const payload = b.bytes ?? JSON.stringify(b.body ?? {})
    return new Response(payload, { status: b.status ?? 200, headers: b.headers ?? { 'content-type': 'application/json', server: 'uvicorn', 'set-cookie': 'a=b' } })
  }
  return w
}
const post = (h, body, { auth = 'Bearer tok', origin = 'https://derm.unclogme.app' } = {}) => h(new Request('https://x/functions/v1/lwt-monthly', { method: 'POST', headers: { Authorization: auth, origin, 'content-type': 'application/json' }, body: JSON.stringify(body) }))
const raw = (h, bytes) => h(new Request('https://x/functions/v1/lwt-monthly?action=read_invoice', { method: 'POST', headers: { Authorization: 'Bearer tok', origin: 'https://derm.unclogme.app', 'content-type': 'application/octet-stream' }, body: bytes }))

async function run(h, hOff) {
  const out = []
  const t = async (name, fn) => { try { await fn(); out.push([name, null]) } catch (e) { out.push([name, e.message]) } }
  const eq = (a, b, what) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${what}: got ${JSON.stringify(a)}, expected ${JSON.stringify(b)}`) }
  const ok = (v, what) => { if (!v) throw new Error(what) }

  await t('no token: 401, bot not called', async () => { const w = world(); const r = await h(new Request('https://x/', { method: 'POST', body: '{}' })); eq(r.status, 401, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('not signed in: 401, bot not called', async () => { const w = world({ signedIn: false }); const r = await post(h, { action: 'overview' }); eq(r.status, 401, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('not staff: 403, bot not called', async () => { const w = world({ staff: false }); const r = await post(h, { action: 'overview' }); eq(r.status, 403, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('unknown action: 400, bot not called', async () => { const w = world(); const r = await post(h, { action: 'process_one' }); eq(r.status, 400, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('an inherited name is not an action', async () => { const w = world(); const r = await post(h, { action: 'constructor' }); eq(r.status, 400, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('a path in the body goes nowhere', async () => { const w = world(); await post(h, { action: 'tickets', path: '/gdo/process-one', url: 'https://evil.example' }); eq(w.botCalls.map((c) => c.url), ['https://bot.example/monthly/fetch?unreported=1'], 'url') })
  await t('a filing id cannot carry a path', async () => { const w = world(); const r = await post(h, { action: 'download', id: '1/../../gdo/process-one' }); eq(r.status, 400, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('no DERM Tracker access: 403 on a read, bot not called', async () => { const w = world({ deny: { [VIEW]: { status: 403, message: 'No' } } }); const r = await post(h, { action: 'tickets' }); eq(r.status, 403, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('View only: a read passes', async () => { const w = world({ deny: { [EDIT]: { status: 403, message: 'No' } } }); const r = await post(h, { action: 'tickets' }); eq(r.status, 200, 'status'); eq(w.botCalls.length, 1, 'bot') })
  for (const action of ['check', 'generate', 'record', 'discard', 'restore', 'archive', 'unarchive', 'save_size', 'save_work']) {
    await t(`View only: ${action} refused, nothing sent`, async () => { const w = world({ deny: { [EDIT]: { status: 403, message: 'No' } } }); const r = await post(h, { action, payload: {}, id: 1, expect_tickets: ['1'], period: '2026-10', ticket: '1' }); eq(r.status, 403, 'status'); eq(w.botCalls.length + w.rpcCalls.length + w.uploads.length, 0, 'calls') })
  }
  await t('View only: an invoice read is refused', async () => { const w = world({ deny: { [EDIT]: { status: 403, message: 'No' } } }); const r = await raw(h, new Uint8Array([1, 2])); eq(r.status, 403, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('the key goes to the bot and never back', async () => { const w = world({ bot: { status: 200, body: { current: {}, rows: [] } } }); const r = await post(h, { action: 'overview' }); eq(w.botCalls[0].init.headers['x-run-key'], 'k-derm', 'key'); const text = await r.text(); ok(!text.includes('k-derm'), 'key leaked') })
  await t('overview says who is asking', async () => { world({ bot: { status: 200, body: { current: { period: 'October 2026' }, rows: [] } }, deny: { [EDIT]: { status: 403, message: 'No' } } }); const j = await (await post(h, { action: 'overview' })).json(); eq(j.me, { name: 'Diego', email: 'person@unclogme.com', can_edit: false }, 'me'); eq(j.current.period, 'October 2026', 'data') })
  await t('the acting person goes to the bot', async () => { const w = world(); await post(h, { action: 'tickets' }); eq(w.botCalls[0].init.headers['x-acting-user'], 'Diego', 'actor') })
  await t('record: the name comes from the session, dry_run is false', async () => { const w = world(); await post(h, { action: 'record', id: 7, expect_tickets: ['900001'] }); eq(JSON.parse(w.botCalls[0].init.body), { id: 7, filed_by_email: 'person@unclogme.com', dry_run: false, expect_tickets: ['900001'] }, 'body') })
  await t('record: a typed email is refused', async () => { const w = world(); const r = await post(h, { action: 'record', id: 7, expect_tickets: ['1'], filed_by_email: 'x@y.z' }); eq(r.status, 400, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('record: dry_run from a person is refused', async () => { const w = world(); const r = await post(h, { action: 'record', id: 7, expect_tickets: ['1'], dry_run: true }); eq(r.status, 400, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('record: no ticket list, refused', async () => { const w = world(); const r = await post(h, { action: 'record', id: 7 }); eq(r.status, 400, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('check: the signature and summary reach the browser', async () => { world({ bot: { status: 200, body: { html: '', findings: [] }, headers: { 'content-type': 'application/json', 'x-preview-token': 'tok1', 'x-preview-rows': '3', server: 'uvicorn', 'set-cookie': 'a=b' } } }); const r = await post(h, { action: 'check', payload: { year: 2026 } }); eq(r.headers.get('x-preview-token'), 'tok1', 'token'); ok(/x-preview-token/i.test(r.headers.get('access-control-expose-headers') ?? ''), 'not exposed'); eq(r.headers.get('server'), null, 'server header'); eq(r.headers.get('set-cookie'), null, 'cookie') })
  await t('generate: the file and its filing headers pass through, byte for byte', async () => { const bytes = new Uint8Array([80, 75, 3, 4, 0, 255]); world({ bot: { status: 200, bytes, headers: { 'content-type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'content-disposition': 'attachment; filename="LWT_2026-10_1.xlsx"', 'x-filing-id': '9', 'x-filing-list': '%5B%5D' } } }); const r = await post(h, { action: 'generate', payload: { year: 2026 } }); eq([...new Uint8Array(await r.arrayBuffer())], [...bytes], 'bytes'); eq(r.headers.get('x-filing-id'), '9', 'id'); ok(/content-disposition/i.test(r.headers.get('access-control-expose-headers') ?? ''), 'name not exposed') })
  await t('a refusal in words passes through', async () => { world({ bot: { status: 409, body: { detail: 'stale or missing preview' } } }); const r = await post(h, { action: 'generate', payload: {} }); eq(r.status, 409, 'status'); eq((await r.json()).detail, 'stale or missing preview', 'detail') })
  await t('the bot refusing our key never reads as signed out', async () => { world({ bot: { status: 401, body: { detail: 'Invalid x-run-key header' } } }); const r = await post(h, { action: 'tickets' }); eq(r.status, 502, 'status'); ok(/Tell Fred/.test((await r.json()).message), 'words') })
  await t('the tracker refusing a filing is named', async () => { world({ bot: { status: 502, body: { detail: 'upstream said no', refused_by: 'tracker' } } }); const j = await (await post(h, { action: 'record', id: 1, expect_tickets: ['1'] })).json(); eq(j.refused_by, 'tracker', 'who'); eq(j.message, 'upstream said no', 'words') })
  await t('no answer on a read: nothing changed', async () => { world({ botThrows: true }); const r = await post(h, { action: 'tickets' }); eq(r.status, 502, 'status'); ok(/Nothing changed/.test((await r.json()).message), 'words') })
  await t('no answer on a filing: it says check first', async () => { world({ botThrows: true }); const j = await (await post(h, { action: 'record', id: 1, expect_tickets: ['1'] })).json(); ok(/Check the filing history/.test(j.message), 'words') })
  await t('the invoice goes as raw bytes', async () => { const w = world({ bot: { status: 200, body: { tickets: [] } } }); const r = await raw(h, new Uint8Array([37, 80, 68, 70])); eq(r.status, 200, 'status'); eq(w.botCalls[0].url, 'https://bot.example/monthly/invoice-parse', 'url'); eq([...new Uint8Array(w.botCalls[0].init.body)], [37, 80, 68, 70], 'bytes') })
  await t('an invoice over 10 MB is refused here', async () => { const w = world(); const r = await raw(h, new Uint8Array(10 * 1024 * 1024 + 1)); eq(r.status, 413, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('board, suggest, save_size run as the caller, in derm', async () => { const w = world(); await post(h, { action: 'board', tickets: ['1'] }); await post(h, { action: 'suggest', dump_date: '2026-10-09', vehicle_id: 1 }); await post(h, { action: 'save_size', property_id: 5, gallons: 750 }); eq(w.rpcCalls.map((c) => c.url.split('/').pop()), ['lwt_board', 'lwt_stop_suggestions', 'lwt_save_trap_size'], 'fns'); for (const c of w.rpcCalls) { eq(c.init.headers.Authorization, 'Bearer tok', 'caller token'); eq(c.init.headers['Content-Profile'], 'derm', 'schema') } eq(w.botCalls.length, 0, 'bot') })
  await t('a refused trap size comes back in words', async () => { const w = world(); w.rpcStatus = 400; w.rpcAnswer = { code: '22023', message: 'This property already has a trap size (500 gallons). Change it in the Client App.' }; const r = await post(h, { action: 'save_size', property_id: 5, gallons: 750 }); eq(r.status, 400, 'status'); ok(/already has a trap size/.test((await r.json()).message), 'words') })
  await t('work: a bad month is refused', async () => { const w = world(); const r = await post(h, { action: 'save_work', period: '../../x', work: {} }); eq(r.status, 400, 'status'); eq(w.uploads.length, 0, 'upload') })
  await t('work: saved under the month, by the person', async () => { const w = world(); const r = await post(h, { action: 'save_work', period: '2026-10', work: { schema: 2 } }); eq(r.status, 200, 'status'); eq(w.uploads[0].b, 'lwt-monthly-work', 'bucket'); eq(w.uploads[0].p, '2026-10.json', 'path'); eq(w.uploads[0].o.upsert, true, 'upsert'); const j = JSON.parse(w.uploads[0].text); eq(j.saved_by, 'Diego', 'by'); eq(j.work, { schema: 2 }, 'work') })
  await t('work: a month with nothing saved reads as null', async () => { world(); const j = await (await post(h, { action: 'load_work', period: '2026-10' })).json(); eq(j, { work: null }, 'answer') })
  await t('work: a failed save is said', async () => { world({ workErr: { message: 'boom' } }); const r = await post(h, { action: 'save_work', period: '2026-10', work: {} }); eq(r.status, 500, 'status'); ok(/before closing/.test((await r.json()).message), 'words') })
  await t('off: no connection, 503, nothing sent', async () => { const w = world(); const r = await post(hOff, { action: 'tickets' }); eq(r.status, 503, 'status'); eq(w.botCalls.length, 0, 'bot') })
  await t('off: the database side still answers', async () => { const w = world(); const r = await post(hOff, { action: 'suggest', dump_date: '2026-10-09' }); eq(r.status, 200, 'status'); eq(w.rpcCalls.length, 1, 'rpc') })
  await t('CORS: another site gets our origin back, not its own', async () => { world(); const r = await post(h, { action: 'tickets' }, { origin: 'https://evil.example' }); eq(r.headers.get('access-control-allow-origin'), 'https://derm.unclogme.app', 'origin') })
  await t('CORS: the Ops Portal is allowed', async () => { world(); const r = await post(h, { action: 'tickets' }, { origin: 'https://ops.unclogme.app' }); eq(r.headers.get('access-control-allow-origin'), 'https://ops.unclogme.app', 'origin') })
  return out
}

console.error = () => {}   // the function logs its refusals; they are expected here
const src = fs.readFileSync(path.join(REPO, FN), 'utf8')
const real = build('real', src)
const results = await run(await load(real, ON, 'on'), await load(real, OFF, 'off'))
const failed = results.filter(([, e]) => e)
for (const [name, e] of failed) console.log(`FAIL ${name}: ${e}`)
console.log(`${results.length - failed.length} of ${results.length} scenarios hold`)

// Each guard removed in a copy: the scenarios above must notice. A check that cannot fail proves nothing.
const MUTANTS = [
  ['access check removed', "if (denied) return json({ error: 'no_access', message: denied.message }, denied.status, cors)", ''],
  ['edit actions read as view', "level === 'edit' ? 'lwt_monthly_edit' : 'lwt_monthly_view'", "'lwt_monthly_view'"],
  ['typed email and dry_run accepted', "if ('filed_by_email' in b || 'dry_run' in b) throw new BadRequest('The name on a filing comes from the sign-in, and this page does not rehearse.')", ''],
  ['record names someone else', 'filed_by_email: sessionEmail,', "filed_by_email: 'someone@else.example',"],
  ['record rehearses instead of filing', 'dry_run: false, expect_tickets', 'dry_run: true, expect_tickets'],
  ['the ticket list is not sent', 'dry_run: false, expect_tickets: b.expect_tickets }', 'dry_run: false }'],
  ['filing id not checked', "if (!/^[0-9]{1,12}$/.test(s)) throw new BadRequest('A filing id is required.')", ''],
  ['a 401 passes through', 'if (r.status === 401) {', 'if (false) {'],
  ['all bot headers pass through', "if (n === 'content-type') out[name] = value", 'out[name] = value; if (false) out[name] = value'],
  ['no size cap on the invoice', 'if (bytes.byteLength > MAX_INVOICE_BYTES)', 'if (false)'],
  ['month not checked on saved work', 'if (!PERIOD_RE.test(period))', 'if (false)'],
  ['staff check removed', "if (!(await isStaffEmail(token, email))) return json({ error: 'forbidden', message: 'Staff account required.' }, 403, cors)", ''],
]
let bad = failed.length
for (let i = 0; i < MUTANTS.length; i++) {
  const [name, from, to] = MUTANTS[i]
  if (!src.includes(from)) { console.log(`MUTANT TARGET MISSING: ${name}`); bad++; continue }
  const file = build(`m${i}`, src.replace(from, to))
  const res = await run(await load(file, ON, `m${i}on`), await load(file, OFF, `m${i}off`))
  const caught = res.filter(([, e]) => e).length
  console.log(`${caught ? 'caught' : 'NOT CAUGHT'} (${caught} scenarios fail): ${name}`)
  if (!caught) bad++
}
fs.rmSync(TMP, { recursive: true, force: true })
if (bad) { console.log(`FAILED: ${bad}`); process.exit(1) }
console.log('OK')
