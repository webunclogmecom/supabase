// v5-live.mjs <intake id> : question list version 5 on the LIVE collector form and the REAL server (Trello 6t3RDVkE,
// 2026-10-22): "How can you give us its size?" shows the model box or the measurements box, a model is typed and the form
// is submitted; then the trigger's AI lookup lands in public.grease_trap_size_lookups and the Property record tab's
// compare OFFERS its gallons (read as Fred). Nothing is ever saved to the property. Refuses anything but an OPEN version 5
// intake whose requested_by starts with "[TEST]" on property 1164 or 162 (the test client 112-YA). Reads the token from
// the DB and never prints it. SUBMITS the intake; remove it with the per-id recipe of Building Apps/docs/client-intake-flow.md
// 11.3 step 5 (the lookup row stays: it is reference data about a real model).
//   node scripts/intake-collector/tests/v5-live.mjs <intake id> [model text, default "Schier GB-75"]
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const id = Number(process.argv[2]), MODEL = process.argv[3] || 'Schier GB-75'
const [row] = await sql(`select token, property_id, requested_by, submitted_at, cancelled_at, form_snapshot ->> 'version' as v from public.property_intakes where id = ${id}`)
if (!row || !/^\[TEST\]/.test(row.requested_by || '') || ![1164, 162].includes(Number(row.property_id)) || row.submitted_at || row.cancelled_at || row.v !== '5') throw new Error('needs an OPEN version 5 [TEST] intake on 1164 or 162')
const TOKEN = row.token
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${c || v === undefined ? '' : ' :: ' + String(JSON.stringify(v)).replaceAll(TOKEN, '<token>').slice(0, 400)}`) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true })
const page = await ctx.newPage()
const errors = []; page.on('pageerror', (e) => errors.push(String(e)))
await page.goto('https://planner.unclogme.app/intake.html#code=' + TOKEN)
await page.waitForSelector('[data-q="grease_trap.systems_count"]', { timeout: 30000 })
const shown = (k) => page.locator(`[data-q="${k}"]`).isVisible().catch(() => false)
ok(!(await shown('grease_trap.size_from')), 'before a trap is counted, "How can you give us its size?" is hidden')
await page.locator('[data-q="grease_trap.systems_count"]').getByRole('button', { name: 'One more' }).click(); await page.waitForTimeout(300)
const choice = page.locator('[data-q="grease_trap.size_from"]')
ok(await shown('grease_trap.size_from') && (await choice.textContent()).includes('How can you give us its size?'), 'one trap: the choice shows')
ok(await choice.getByRole('button', { name: 'Model on the plate' }).isVisible() && await choice.getByRole('button', { name: 'Measurements' }).isVisible(), 'its two answers: Model on the plate, Measurements')
ok(!(await shown('grease_trap.model')) && !(await shown('grease_trap.capacity_measure')) && await shown('grease_trap.capacity_gallons'), 'nothing picked: no model box, no measurements box, Gallons shows')
await choice.getByRole('button', { name: 'Measurements' }).click(); await page.waitForTimeout(300)
ok(await shown('grease_trap.capacity_measure') && !(await shown('grease_trap.model')), 'Measurements: the measurements box only')
await choice.getByRole('button', { name: 'Model on the plate' }).click(); await page.waitForTimeout(300)
ok(await shown('grease_trap.model') && !(await shown('grease_trap.capacity_measure')), 'Model on the plate: the model box only')
const mb = page.locator('[data-f="grease_trap.model"]').first()
await mb.fill(MODEL); await mb.dispatchEvent('input'); await page.waitForTimeout(300)
ok(!(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)), '390 wide: no sideways scroll')
await page.locator('[data-q="grease_trap.size_from"]').scrollIntoViewIfNeeded(); await page.screenshot({ path: (process.env.OUT || '.') + `/v5_live_${id}.png` }).catch(() => {})
await page.fill('#who', '[TEST] v5 live')
await page.click('#send')
const cf = page.getByRole('button', { name: 'Submit anyway' })
if (await cf.isVisible().catch(() => false)) await cf.click()
await page.waitForFunction(() => /Thank you|Could not|refused|not valid/i.test(document.getElementById('main').textContent), null, { timeout: 20000 }).catch(() => {})
ok(/Thank you/.test(await page.textContent('main')), 'submitted: the thank-you screen')
ok(errors.length === 0, 'no page errors', errors)
await browser.close()
const [s] = await sql(`select submitted_at is not null as done, answers -> 'grease_trap.size_from' ->> 'value' as f, answers -> 'grease_trap.model' ->> 'value' as m from public.property_intakes where id = ${id}`)
ok(s && s.done && s.f === 'Model on the plate' && s.m === MODEL, 'the stored answers: Model on the plate, and the model as typed', s)
// the trigger asked for the lookup at submit: wait for its row (a web search takes up to about a minute)
let L = null
for (let i = 0; i < 18 && !(L && L.status && L.status !== 'error'); i++) {
  await new Promise((r) => setTimeout(r, 10000))
  ;[L] = await sql(`select g.id, g.status, g.gallons, g.source_url, g.summary, g.attempts from public.grease_trap_size_lookups g where g.kind = 'model' and g.input_key = public.fn_size_lookup_key('${MODEL.replace(/'/g, "''")}')`)
}
ok(!!L && ['found', 'not_found'].includes(L.status), 'the AI lookup ran on its own after the submit (trigger), and answered', L)
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_intake(${id}) -> 'size_lookups' as sl, (select f from jsonb_array_elements(client.get_intake_compare(${id}) -> 'fields') f where f ->> 'key' = 'grease_trap.capacity_gallons') as g,
       (select grease_trap_size_gallons from public.properties where id = ${row.property_id}) as on_file;`)
const x = r[r.length - 1]
ok(x.sl && x.sl.length === 1 && x.sl[0].key === 'grease_trap.model' && x.sl[0].status === L?.status, 'get_intake shows the lookup under the model', x.sl)
if (L && L.status === 'found') {
  ok(x.g && x.g.offer && x.g.offer.gallons === L.gallons && x.g.offer.kind === 'model' && x.g.offer.input_text === MODEL && x.g.theirs === L.gallons
     && x.g.state === (x.on_file == null ? 'blank' : x.on_file === L.gallons ? 'same' : 'differs'), 'the Property record tab offers the AI gallons (nothing saved)', { g: x.g, on_file: x.on_file })
} else ok(x.g && !x.g.offer, 'not found: nothing is offered', x.g)
const [acc] = await sql(`select count(*)::int as n from public.property_intake_accepts where intake_id = ${id}`)
ok(acc.n === 0, 'nothing was saved to the property')
console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
