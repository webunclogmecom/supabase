// Standing check: rpa-derm-result records a "File it with the bot" press as a real filing, ignores a dry press, and
// names the permit from gdo_number when the bot sends no gdo_id (2026-10-29, Trello xBCSvP6f).
//
//   node scripts/checks/rpa_derm_result_button_press.mjs [control-ref]     (default control: f4a81997, before the change)
//
// Runs the REAL function offline (esbuild strips the two imports; stubs replace createClient, Deno.serve and fetch).
// The working tree must give the expected answer in every scenario; the CONTROL body (before the change) must FAIL
// the ones the change exists for, or the check proves nothing. Exit 0 = both hold. Needs node + npx esbuild@0.24.0.
// Migration: docs/migrations/2026-10-29_1245_gdo_bot_file_requests.sql (the press log + the guard branch).
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { pathToFileURL, fileURLToPath } from 'node:url'

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const FN = 'supabase/functions/rpa-derm-result/index.ts'
const CONTROL_REF = process.argv[2] || 'f4a81997'
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'rpa-press-'))

fs.writeFileSync(path.join(TMP, 'stub.mjs'), [
  'export function createClient() { return globalThis.__sb }',
  "export const slackHeader = (t) => ({ type: 'header', text: t })",
  "export const slackSections = (b) => [{ type: 'section', text: b }]",
  "export const slackIdentity = async () => ({ username: 'DERM Tracker' })",
].join('\n'))

function build(name, src) {
  const a = "import { createClient } from 'jsr:@supabase/supabase-js@2'"
  const b = "import { slackHeader, slackIdentity, slackSections } from '../_shared/slack-notify.ts'"
  if (!src.includes(a) || !src.includes(b)) throw new Error(`${name}: import lines changed, update this check`)
  src = src.replace(a, "import { createClient } from './stub.mjs'").replace(b, "import { slackHeader, slackIdentity, slackSections } from './stub.mjs'")
  const ts = path.join(TMP, `${name}.ts`), out = path.join(TMP, `${name}.mjs`)
  fs.writeFileSync(ts, src)
  execFileSync(process.platform === 'win32' ? 'npx.cmd' : 'npx', ['--no-install', 'esbuild@0.24.0', ts, '--format=esm', `--outfile=${out}`, '--log-level=error'], { shell: process.platform === 'win32' })
  return out
}

const ENV = { RPA_BOT_KEYS: 'k1', SUPABASE_URL: 'http://x', SUPABASE_SERVICE_ROLE_KEY: 's', SLACK_BOT_TOKEN: 't' }
async function load(name, file) {
  let handler
  globalThis.Deno = { env: { get: (k) => ENV[k] }, serve: (h) => { handler = h } }
  await import(pathToFileURL(file).href + `?${name}`)
  if (!handler) throw new Error(`${name}: Deno.serve was never called`)
  return handler
}

// Visit 8096 (246-LOUI) on ticket 839776: its permit GDO-12656 (217). A second permit 253 (GDO-16046) is put on the
// visit in the scenarios that need two, and inference is made to answer 253, so only a real number match gives 217.
const OLD = { id: 1251, deleted_at: null, visit_date: '2026-01-05', client_id: 501 }
const NEW = { id: 8096, deleted_at: null, visit_date: '2026-10-22', client_id: 501 }
const TWO = [{ gdo_id: 217, gdo_number: 'GDO-12656' }, { gdo_id: 253, gdo_number: 'GDO-16046' }]

function makeSb(sc) {
  const inserts = []
  const answer = (table, f, mode) => {
    if (table === 'visits') return { data: sc.visit, error: null }
    if (table === 'gdo_bot_file_requests') return sc.pressErr ? { data: null, error: { message: 'boom' } } : { data: sc.press ?? null, error: null }
    if (table === 'derm_portal_submissions') return { data: null, error: null }
    if (table === 'v_derm_portal_fields') {
      const rows = (sc.fields ?? TWO).filter((r) => f.gdo_id === undefined || r.gdo_id === f.gdo_id)
      return { data: rows, error: null }
    }
    if (table === 'gdos') {
      const rows = (sc.clientPermits ?? TWO.map((r) => ({ id: r.gdo_id, gdo_number: r.gdo_number })))
        .filter((g) => f.id === undefined || g.id === f.id)
      return { data: rows, error: null }
    }
    throw new Error(`unexpected table ${table} (${mode})`)
  }
  return {
    from(table) {
      const f = {}
      const b = {
        select() { return b }, eq(k, v) { f[k] = v; return b }, limit() { return b },
        maybeSingle: async () => answer(table, f, 'maybeSingle'),
        then(res, rej) { return Promise.resolve(answer(table, f, 'then')).then(res, rej) },
        insert(row) {
          inserts.push({ table, row })
          return { select: () => ({ single: async () => ({ data: { id: 9001 }, error: null }) }) }
        },
      }
      return b
    },
    rpc: async (name) => name === 'rpa_launch_cutoff' ? { data: '2026-07-21', error: null }
      : name === 'fn_resolve_rpa_permit' ? { data: sc.inferred ?? 253, error: null } : { data: null, error: null },
    storage: { from: () => ({ upload: async () => ({ error: null }) }) },
    inserts,
  }
}

const body = (over = {}) => ({ visit_id: 8096, run_id: 'run-7f3a', status: 'SUCCESS', retryable: false,
  attempted_at: '2026-10-29T16:00:00Z', portal_confirmation: 'Submitted - DERM portal confirmed', screenshot_missing_reason: 'check', ...over })
const sub = (r) => r.sb.inserts.find((i) => i.table === 'derm_portal_submissions')?.row

const SCENARIOS = [
  { id: 'older visit, no press: stays a dry run (as today)', sc: { visit: OLD, fields: [TWO[0]] }, b: body({ visit_id: 1251, gdo_id: 217 }),
    ok: (r) => r.status === 201 && sub(r)?.dry_run === true && sub(r)?.filed_by_email == null },
  { id: 'older visit, live press: real filing by the presser', change: true,
    sc: { visit: OLD, fields: [TWO[0]], press: { gdo_id: 217, dry_run: false, requested_by: 'yannick@ayache.com' } }, b: body({ visit_id: 1251 }),
    ok: (r) => r.status === 201 && sub(r)?.dry_run === false && sub(r)?.filed_by_email === 'yannick@ayache.com' && sub(r)?.gdo_id === 217 },
  { id: 'newer visit, live press: filed_by is the presser', change: true,
    sc: { visit: NEW, press: { gdo_id: 217, dry_run: false, requested_by: 'yannick@ayache.com' } }, b: body(),
    ok: (r) => r.status === 201 && sub(r)?.dry_run === false && sub(r)?.filed_by_email === 'yannick@ayache.com' && sub(r)?.gdo_id === 217 },
  { id: 'dry press: never recorded', change: true, sc: { visit: NEW, press: { gdo_id: 217, dry_run: true, requested_by: 'fred@ayache.com' } }, b: body(),
    ok: (r) => r.status === 200 && r.out.ignored === 'dry_run_press' && !sub(r) },
  { id: 'press lookup fails: 500, nothing written', change: true, sc: { visit: OLD, pressErr: true }, b: body({ visit_id: 1251 }),
    ok: (r) => r.status === 500 && !sub(r) },
  { id: 'gdo_number GDO-12656 names the permit (inference says 253)', change: true, sc: { visit: NEW }, b: body({ gdo_number: 'GDO-12656' }),
    ok: (r) => r.status === 201 && sub(r)?.gdo_id === 217 },
  { id: 'gdo_number 0012656 (no prefix, zeros) names it', change: true, sc: { visit: NEW }, b: body({ gdo_number: '0012656' }),
    ok: (r) => r.status === 201 && sub(r)?.gdo_id === 217 },
  { id: 'gdo_number not on the visit, one client permit matches', change: true,
    sc: { visit: NEW, fields: [TWO[1]], clientPermits: [{ id: 217, gdo_number: 'GDO-12656' }, { id: 253, gdo_number: 'GDO-16046' }] },
    b: body({ gdo_number: 'GDO-12656' }), ok: (r) => r.status === 201 && sub(r)?.gdo_id === 217 },
  { id: 'gdo_number matching two permits falls back to inference', sc: { visit: NEW, fields: [],
      clientPermits: [{ id: 217, gdo_number: 'GDO-12656' }, { id: 300, gdo_number: 'GDO-012656' }] },
    b: body({ gdo_number: '12656' }), ok: (r) => r.status === 201 && sub(r)?.gdo_id === 253 },
  { id: 'gdo_id wins over gdo_number', sc: { visit: NEW }, b: body({ gdo_id: 253, gdo_number: 'GDO-12656' }),
    ok: (r) => r.status === 201 && sub(r)?.gdo_id === 253 },
  { id: 'neither: inference, as today', sc: { visit: NEW }, b: body(), ok: (r) => r.status === 201 && sub(r)?.gdo_id === 253 },
  { id: 'a blank number "GDO-" is no number', sc: { visit: NEW }, b: body({ gdo_number: 'GDO-' }), ok: (r) => r.status === 201 && sub(r)?.gdo_id === 253 },
]

async function call(handler, s) {
  const sb = makeSb(s.sc)
  globalThis.__sb = sb
  const res = await handler(new Request('http://x/', { method: 'POST', headers: { 'x-rpa-key': 'k1', 'content-type': 'application/json' }, body: JSON.stringify(s.b) }))
  let out = null
  try { out = await res.json() } catch { out = null }
  return { status: res.status, out, sb }
}

const work = build('work', fs.readFileSync(path.join(REPO, FN), 'utf8'))
const control = build('control', execFileSync('git', ['show', `${CONTROL_REF}:${FN}`], { cwd: REPO, encoding: 'utf8', maxBuffer: 8e6 }))
const H = { work: await load('work', work), control: await load('control', control) }

let ok = true
const quiet = { error: console.error, info: console.info }
const check = (label, cond, extra = '') => { console.log(`${cond ? 'PASS' : 'FAIL'}  ${label}${extra ? '  ' + extra : ''}`); if (!cond) ok = false }
const run = async (h, s) => { console.error = () => {}; console.info = () => {}; try { return await call(h, s) } finally { Object.assign(console, quiet) } }

for (const s of SCENARIOS) {
  const r = await run(H.work, s)
  check(`${s.id}: working tree`, s.ok(r), `HTTP ${r.status} ${JSON.stringify(sub(r) ?? r.out).slice(0, 140)}`)
}
for (const s of SCENARIOS.filter((x) => x.change)) {
  const r = await run(H.control, s)
  check(`${s.id}: control (${CONTROL_REF}) must FAIL it`, !s.ok(r), `HTTP ${r.status}`)
}

fs.rmSync(TMP, { recursive: true, force: true })
console.log(ok ? '\nRESULT: OK' : '\nRESULT: FAILED')
process.exit(ok ? 0 : 1)
