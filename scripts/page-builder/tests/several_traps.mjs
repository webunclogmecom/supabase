// LIVE Picture Planner /forms/<id>: several grease traps (question list version 6, 2026-10-23). Real replies of a
// version 6 [TEST] form with 3 traps (default 1119, 112-YA) read as Fred's claims; scenario B edits the offer so one trap
// has no number. Sign-in faked; every call stubbed; Save is RECORDED, nothing is written.
// Spec: Building Apps/Picture Planner/docs/specs/2026-10-23-several-grease-traps-and-map-pins-design.md
//   node scripts/page-builder/tests/several_traps.mjs <outdir> [intake id]
//   CHUNK_SUB='<from>|||<to>@@@...' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const ID = Number(process.argv[3] || 1119)
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_intake(${ID}) as i, client.get_intake_compare(${ID}) as c,
       (select jsonb_agg(to_jsonb(s)) from client.v_intake_submissions s where s.intake_id = ${ID}) as subs;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
const G = row && row.c && row.c.fields.find((f) => f.key === 'grease_trap.capacity_gallons')
if (!G || !G.offer || G.offer.kind !== 'traps' || G.offer.traps.length !== 3) { console.log('FAIL fixture: form ' + ID + ' must offer a 3-trap total :: ' + JSON.stringify(G).slice(0, 300)); process.exit(1) }
const clone = (x) => JSON.parse(JSON.stringify(x))
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 400)}`) }
const cmp = (edit) => { const c = clone(row.c); c.can_accept = true; c.accept_blocker = null; const f = c.fields.find((x) => x.key === 'grease_trap.capacity_gallons'); if (edit) edit(f); return c }
const PART = (f) => { f.offer.gallons = null; f.offer.traps[2] = { ...f.offer.traps[2], gallons: null, from: null, input_text: null, summary: null, source_url: null, lookup_id: null }; f.theirs = null; f.state = 'not_savable' }

const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp, user }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './several_traps_shots'; fs.mkdirSync(out, { recursive: true })
async function open(w, C) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { bodies: [], errors: [] }
  p.on('pageerror', (e) => { if (!/Google Maps/.test(String(e))) st.errors.push(String(e)) })
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => {
    const n = new URL(x.request().url()).pathname.split('/').pop()
    let b = {}; try { b = JSON.parse(x.request().postData() || '{}') } catch {}
    const send = (v) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(v) })
    if (n === 'accept_intake_answers') { st.bodies.push(b); return send({ ok: true, intake_id: b.p_intake_id, accepted: b.p_keys }) }
    if (n === 'get_intake') { const i = clone(row.i); i.accepted = []; return send(i) }
    if (n === 'get_intake_compare') return send(C)
    if (n === 'v_intake_submissions') return send(row.subs)
    if (n === 'get_my_access') return send({ ok: true })
    return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' })
  })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [a, c] of pairs) t = t.split(a).join(c); await x.fulfill({ status: 200, contentType: 'application/javascript', body: t }) }) }
  await p.goto(H + '/forms/' + ID)
  await p.waitForFunction(() => /answered/.test(document.body.textContent), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(2000)
  return { ctx, p, st }
}
const toRecord = async (p) => { await p.getByRole('tab', { name: 'Property record' }).click({ timeout: 5000 }).catch(() => {}); await p.waitForFunction(() => document.querySelectorAll('[data-accept-row]').length > 0, null, { timeout: 15000 }).catch(() => {}); await p.waitForTimeout(500) }
const offer = (p) => p.evaluate(() => { const r = document.querySelector('[data-accept-row="grease_trap.capacity_gallons"]'); if (!r) return null; const o = r.querySelector('[data-ai-offer]'); const n = r.querySelector('[data-accept-note]'); return { kind: o && o.getAttribute('data-ai-offer'), offer: o ? o.textContent.replace(/\s+/g, ' ').trim() : null, note: n ? n.textContent.replace(/\s+/g, ' ').trim() : null, text: r.textContent.replace(/\s+/g, ' ').trim(), links: [...r.querySelectorAll('a')].map((a) => ({ href: a.getAttribute('href'), target: a.getAttribute('target'), rel: a.getAttribute('rel') })) } })
const sideways = (p) => p.evaluate(() => document.documentElement.scrollWidth > innerWidth)
const n1 = (s) => (s || '').replace(/,/g, '')

for (const w of [390, 1280]) {
  // A. the real 3-trap form: each trap's questions and its own AI lookup box on the Answers tab; the total on the Property record tab
  let { ctx, p, st } = await open(w, cmp())
  const ans = await p.evaluate(() => document.body.textContent.replace(/\s+/g, ' '))
  ok(/Grease trap 2: how can you give us its size\?/.test(ans) && /Grease trap 3: how can you give us its size\?/.test(ans), `A ${w}: the Answers tab lists trap 2 and trap 3's own questions`)
  const boxes = await p.evaluate(() => [...document.querySelectorAll('[data-size-lookup]')].map((b) => ({ status: b.getAttribute('data-size-lookup'), text: b.textContent.replace(/\s+/g, ' ').trim().slice(0, 120) })))
  ok(boxes.length === 2 && boxes.every((b) => b.status === 'found') && boxes.some((b) => /125/.test(b.text)) && boxes.some((b) => /75/.test(b.text)), `A ${w}: one AI lookup box per trap (trap 2 model 125 gal, trap 3 measurements 75 gal)`, boxes)
  await p.screenshot({ path: `${out}/A_${w}_answers.png`, fullPage: true }).catch(() => {})
  await toRecord(p)
  const o = await offer(p)
  ok(o && o.kind === 'traps', `A ${w}: the Gallons row marks a several-trap offer (data-ai-offer="traps")`, o)
  ok(o && /Total of the 3 grease traps/.test(o.offer || o.text), `A ${w}: "Total of the 3 grease traps"`, o && o.offer)
  const t = (o && (o.offer || o.text)) || ''
  ok(/Grease trap 1: 1,?000 gal, typed on the form/.test(t), `A ${w}: trap 1's line (typed on the form)`, t)
  ok(/Grease trap 2: 125 gal, AI lookup of Schier GB-75/.test(t), `A ${w}: trap 2's line (AI lookup of the model)`, t)
  ok(/Grease trap 3: 75 gal, from the measurements/.test(t), `A ${w}: trap 3's line (from the measurements)`, t)
  ok(/1200/.test(n1(o && o.text)), `A ${w}: the row shows the total 1,200`, o && o.text)
  ok(o && o.links.every((l) => /^https?:/.test(l.href) && l.target === '_blank' && /noopener/.test(l.rel || '')), `A ${w}: every source link opens a new tab safely`, o && o.links)
  ok(!(await sideways(p)), `A ${w}: no sideways scroll`)
  await p.screenshot({ path: `${out}/A_${w}_record.png`, fullPage: true }).catch(() => {})
  // Save the gallons row only: the app sends the key, never the number
  const tick = p.locator('[data-accept-row="grease_trap.capacity_gallons"] input[type="checkbox"], [data-accept-row="grease_trap.capacity_gallons"] [role="checkbox"]').first()
  if (await tick.isVisible().catch(() => false) && (await tick.getAttribute('aria-checked').catch(() => null)) !== 'true' && !(await tick.isChecked().catch(() => false))) await tick.click().catch(() => {})
  for (const k of ['access_entry.lock_box_code', 'access_hours.schedule', 'grease_trap.manhole_count', 'grease_trap.sample_ports', 'access_entry.equipment_where']) {
    const t2 = p.locator(`[data-accept-row="${k}"] input[type="checkbox"], [data-accept-row="${k}"] [role="checkbox"]`).first()
    if (await t2.isVisible().catch(() => false) && ((await t2.getAttribute('aria-checked').catch(() => null)) === 'true' || await t2.isChecked().catch(() => false))) await t2.click().catch(() => {})
  }
  await p.getByRole('button', { name: /^Save/ }).first().click({ timeout: 5000 }).catch(() => {})
  await p.waitForTimeout(500)
  const confirm = p.getByRole('button', { name: /^(Save|Confirm|Yes, save)/ }).last()
  if (await confirm.isVisible().catch(() => false)) await confirm.click().catch(() => {})
  await p.waitForTimeout(1200)
  const B = st.bodies[0]
  ok(B && B.p_keys && B.p_keys.includes('grease_trap.capacity_gallons') && Object.keys(B).sort().join(',') === 'p_expected,p_intake_id,p_keys' && !JSON.stringify(B).includes('1200'), `A ${w}: Save sends the key and the expected value only, never the 1,200`, B)
  ok(st.errors.length === 0, `A ${w}: no page errors`, st.errors)
  await ctx.close()

  // B. one trap has no number: no total, the row cannot be saved and says why
  ;({ ctx, p, st } = await open(w, cmp(PART)))
  await toRecord(p)
  const o2 = await offer(p)
  ok(o2 && /Grease trap 3: no gallons yet/.test(o2.offer || o2.text), `B ${w}: trap 3 reads "no gallons yet"`, o2 && (o2.offer || o2.text))
  ok(o2 && /Not every grease trap has its gallons yet, so the total cannot be saved here\./.test(o2.text), `B ${w}: the row says the total cannot be saved`, o2 && o2.text)
  const tick2 = p.locator('[data-accept-row="grease_trap.capacity_gallons"] input[type="checkbox"], [data-accept-row="grease_trap.capacity_gallons"] [role="checkbox"]').first()
  ok(!(await tick2.isVisible().catch(() => false)) || (await tick2.isDisabled().catch(() => false)), `B ${w}: no tick on that row`)
  await p.screenshot({ path: `${out}/B_${w}_record.png`, fullPage: true }).catch(() => {})
  ok(st.errors.length === 0, `B ${w}: no page errors`, st.errors)
  await ctx.close()
}
await browser.close()
console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
