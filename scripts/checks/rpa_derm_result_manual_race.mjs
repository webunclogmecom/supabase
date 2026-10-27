// Standing check: rpa-derm-result's manual-entry error branch never deletes a recorded image.
//
//   node scripts/checks/rpa_derm_result_manual_race.mjs [control-ref]     (default control: 4deebe7, the pre-fix body)
//
// Runs recordManualEntry offline (esbuild strips the two imports; stubs replace createClient, Deno.serve and the Slack
// fetch) through seven scenarios of the `if (rpcErr)` branch. The WORKING-TREE body must give the expected answer in
// every one. The CONTROL body must FAIL the three the fix exists for (same-run race won, lost RPC answer, re-read
// error): a check that cannot fail on the old code proves nothing. Exit 0 = both hold.
//
// Why: two requests for one bot run can both pass the dedupe, upload to the same path, and the second RPC gets 23505;
// the pre-fix branch then removed the image the first row points at and posted a false "already filed" alert
// (plan docs/superpowers/plans/2026-10-27-gdo-bot-manual-entry-upstream.md, Part A). Needs node + npx esbuild@0.24.0.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { pathToFileURL, fileURLToPath } from 'node:url'

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const FN = 'supabase/functions/rpa-derm-result/index.ts'
const CONTROL_REF = process.argv[2] || '4deebe7'
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'rpa-race-'))

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

const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 74, 70, 73, 70, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xff, 0xd9]).toString('base64')
const RUN = 'd079deb3-002b-4394-add1-3ddc2b59987d'
const ROW = { id: 2030, visit_id: 8889, gdo_id: 69, screenshot_path: `8889/manual-bot-${RUN}.jpg` }
const body = (over = {}, me = {}) => ({
  visit_id: null, manifest_id: null, run_id: RUN, status: 'SUCCESS', retryable: false,
  attempted_at: '2026-10-27T16:24:48Z', dry_run: false,
  manual_entry: { created_by: 'yan', why: 'entered by hand on the bot dashboard', gdo_number: '14965',
    ticket_number: '487956', service_date: '2025-03-25', ...me },
  screenshot: JPEG, portal_confirmation: 'Submitted - DERM email confirmed', ...over })

function makeSb(sc) {
  const calls = []
  let subReads = 0
  const sb = {
    from(table) {
      const b = {
        select() { return b }, eq() { return b }, limit() { return b },
        then(res, rej) {
          calls.push(`read ${table}`)
          let out
          if (table === 'derm_portal_submissions') out = subReads++ === 0 ? sc.dedupe : sc.reread
          else if (table === 'v_derm_portal_fields') out = { data: [{ visit_id: 8889, gdo_id: 69, gdo_number: 'GDO-14965', ticket_number: '487956', manifest_id: 2090 }], error: null }
          else if (table === 'manifest_visits') out = { data: [{ visit_id: 8889 }], error: null }
          return Promise.resolve(out).then(res, rej)
        },
      }
      return b
    },
    storage: { from: () => ({
      upload: async (p) => { calls.push(`upload ${p}`); return { error: null } },
      remove: async (ps) => { calls.push(`REMOVE ${ps.join(',')}`); return { error: null } } }) },
    rpc: async (fn) => { calls.push(`rpc ${fn}`); return sc.rpc },
  }
  return { sb, calls }
}

async function call(handler, sc, b) {
  const { sb, calls } = makeSb(sc)
  globalThis.__sb = sb
  let slack = 0
  globalThis.fetch = async () => { slack++; return { ok: true, status: 200, json: async () => ({ ok: true }), text: async () => '{"ok":true}' } }
  const res = await handler(new Request('http://x/', { method: 'POST', headers: { 'x-rpa-key': 'k1', 'content-type': 'application/json' }, body: JSON.stringify(b) }))
  return { status: res.status, out: await res.json(), removed: calls.some((c) => c.startsWith('REMOVE')), slack, calls }
}

const none = { data: [], error: null }
const err = (code, message) => ({ data: null, error: code ? { code, message } : { message } })
// expect: HTTP status, whether the image is removed, Slack posts, and a fact about the body
const SCENARIOS = [
  { id: 'S1', label: 'same run recorded first, our RPC 23505', fixFor: true,
    sc: { dedupe: none, reread: { data: [ROW], error: null }, rpc: err('23505', 'duplicate key value') },
    want: { status: 200, removed: false, slack: 0, ok: (o) => o.deduped === true && o.id === 2030 } },
  { id: 'S2', label: 'another run already filed this permit (23505)',
    sc: { dedupe: none, reread: none, rpc: err('23505', 'visit 8889 already has a filing on record for that GDO permit') },
    want: { status: 200, removed: true, slack: 1, ok: (o) => o.reason === 'manual_entry_already_filed' } },
  { id: 'S3', label: 'the re-read itself fails', fixFor: true,
    sc: { dedupe: none, reread: { data: null, error: { message: 'fetch failed' } }, rpc: err('23505', 'dup') },
    want: { status: 500, removed: false, slack: 0, ok: (o) => o.error === 'result_lookup_failed_retry' } },
  { id: 'S4', label: 'RPC committed, only its answer was lost', fixFor: true,
    sc: { dedupe: none, reread: { data: [ROW], error: null }, rpc: err(null, 'TypeError: fetch failed') },
    want: { status: 200, removed: false, slack: 0, ok: (o) => o.deduped === true } },
  { id: 'S5', label: 'transient RPC error, no row',
    sc: { dedupe: none, reread: none, rpc: err(null, 'TypeError: fetch failed') },
    want: { status: 500, removed: false, slack: 0, ok: (o) => o.error === 'result_store_failed_retry' } },
  { id: 'S6', label: '22023 refusal',
    sc: { dedupe: none, reread: none, rpc: err('22023', 'visit 8889 does not exist, is deleted, or is not completed') },
    want: { status: 200, removed: true, slack: 1, ok: (o) => o.reason === 'manual_entry_refused_by_check' } },
  { id: 'S7', label: 'happy path',
    sc: { dedupe: none, reread: none, rpc: { data: { id: 9999 }, error: null } },
    want: { status: 201, removed: false, slack: 0, ok: (o) => o.recorded === true && o.deduped === false } },
]
const meets = (r, w) => r.status === w.status && r.removed === w.removed && r.slack === w.slack && w.ok(r.out)

const quiet = [console.error, console.info, console.warn]
const silence = () => { console.error = console.info = console.warn = () => {} }
const restore = () => { [console.error, console.info, console.warn] = quiet }

const workTree = build('work', fs.readFileSync(path.join(REPO, FN), 'utf8'))
const control = build('control', execFileSync('git', ['-C', REPO, 'show', `${CONTROL_REF}:${FN}`], { encoding: 'utf8' }))
const hWork = await load('work', workTree)
const hCtrl = await load('control', control)

let ok = true
const check = (label, cond, extra = '') => { console.log(`${cond ? 'PASS' : 'FAIL'}  ${label}${extra ? '  ' + extra : ''}`); if (!cond) ok = false }

for (const s of SCENARIOS) {
  silence(); const r = await call(hWork, s.sc, body()); restore()
  check(`${s.id} ${s.label}: working tree`, meets(r, s.want), `HTTP ${r.status} removed=${r.removed} slack=${r.slack} ${JSON.stringify(r.out)}`)
}
for (const s of SCENARIOS.filter((x) => x.fixFor)) {
  silence(); const r = await call(hCtrl, s.sc, body()); restore()
  check(`${s.id} control (${CONTROL_REF}) must FAIL it`, !meets(r, s.want), `HTTP ${r.status} removed=${r.removed} slack=${r.slack}`)
}
silence()
const dedupe = await call(hWork, { dedupe: { data: [ROW], error: null }, reread: none, rpc: {} }, body())
const extra = await call(hWork, { dedupe: none, reread: none, rpc: {} }, body({}, { client_name: 'x' }))
const dry = await call(hWork, { dedupe: none, reread: none, rpc: {} }, body({ run_id: 'fresh-run-1', dry_run: true }))
restore()
check('control: a stored run dedupes before matching, upload or Slack', dedupe.status === 200 && dedupe.out.deduped === true && dedupe.calls.length === 1 && dedupe.slack === 0)
check('control: an extra manual_entry key is a 400', extra.status === 400 && extra.out.error === 'unknown_field_manual_entry.client_name')
check('control: a dry run records nothing and posts nothing', dry.status === 200 && dry.out.recorded === false && dry.slack === 0 && !dry.calls.some((c) => c.startsWith('upload') || c.startsWith('rpc')))

fs.rmSync(TMP, { recursive: true, force: true })
console.log(ok ? '\nRESULT: OK' : '\nRESULT: FAILED')
process.exit(ok ? 0 : 1)
