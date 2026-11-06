// LIVE Picture Planner: the Site file fact light_switches (question list version 8, 2026-11-06, Yan: "if it's inside there the light switch are").
// Page Builder /property/1164 and the public /driver page. Real replies read as Fred's claims, edited in memory; sign-in faked; every call
// stubbed; nothing is written, no open is logged. Then the database's own page rule, in a transaction that is rolled back.
//   node scripts/page-builder/tests/light_switches.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@...' serves the live chunks with those edits (a control: named checks must FAIL)
// Control used on 2026-11-06: CHUNK_SUB='light_switches|||light_switches_x' must fail the fill, the rail and the Site file row.
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const raw = async (q) => { const r = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) }); return { ok: r.ok, text: await r.text() } }
const sql = async (q) => { const r = await raw(q); if (!r.ok) throw new Error(r.text.slice(0, 400)); return JSON.parse(r.text) }
const CLAIMS = `perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);`
const r = await sql(`do $$ begin ${CLAIMS} end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
if (!row || !row.pb || !row.pb.live || !Array.isArray(row.forms) || !row.forms.length) { console.log('FAIL fixture: 1164 needs a live version and a submitted form'); process.exit(1) }
const clone = (x) => JSON.parse(JSON.stringify(x))
const ANSWER = 'Behind the walk-in door, on the left', KEY = 'access_entry.light_switches'
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${c || v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 300)}`) }
const builder = (answer, onPage) => {
  const d = { pb: clone(row.pb), forms: clone(row.forms) }
  d.pb.pending = null
  d.pb.property.source = clone(d.pb.live.source)
  const f = (d.pb.live.content.facts = d.pb.live.content.facts || {}); delete f.light_switches; if (onPage) f.light_switches = onPage
  for (const fm of d.forms) { fm.answers = fm.answers || {}; delete fm.answers[KEY]; if (answer !== undefined) fm.answers[KEY] = answer }
  return d
}
const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp, user }
const ACCESS = { employee_id: 1, group: 'admin', me: { full_name: 'Visual Check', color_hex: null, photo_path: null }, apps: [{ app: 'picture_planner', name: 'Picture Planner', parent: null, mode: 'on', level: 'edit' }, { app: 'pp_forms', name: 'See their assigned forms', parent: 'picture_planner', mode: 'on', level: 'yes' }] }
const FAKE = 'abcdefghijklmnopqrstuv'
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info, apikey, x-app-source' }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './light_switches_shots'; fs.mkdirSync(out, { recursive: true })
async function open(w, path, replies, ready, driver) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  if (!driver) {
    await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
    await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  }
  const p = await ctx.newPage()
  const st = { errors: [] }
  p.on('pageerror', (e) => { if (!/Google Maps|google is not defined/.test(String(e))) st.errors.push(String(e)) })
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); if (n === 'get_my_access') return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(ACCESS) }); return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(n in replies ? replies[n] : []) }) })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route(SB + '/functions/v1/**', (x) => { if (!driver) return x.abort(); if (x.request().method() === 'OPTIONS') return x.fulfill({ status: 204, headers: cors }); return x.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify(driver) }) })
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  await p.route('https://places.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) t = t.split(from).join(to); await x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + path)
  await p.waitForFunction(ready, null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(3000)
  return { ctx, p, st }
}
const openBuilder = (w, answer, onPage) => { const d = builder(answer, onPage); return open(w, '/property/1164', { get_page_builder: d.pb, get_page_builder_forms: d.forms, get_property_activity: [], get_page_versions: [] }, () => /Light switches|Fill empty fields|Where the equipment/.test(document.body.textContent)) }
const draftFact = (p) => p.evaluate(() => { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k.startsWith('pp-draft:')) { try { return (JSON.parse(localStorage.getItem(k)).content.facts || {}).light_switches ?? null } catch {} } } return null })
const box = (p) => p.evaluate(() => { const l = [...document.querySelectorAll('label')].filter((x) => x.getClientRects().length).find((x) => x.textContent.trim().startsWith('Light switches')); if (!l) return { labels: [...document.querySelectorAll('label')].map((x) => x.textContent.trim()).slice(0, 40) }; let c = l, i = null; for (let n = 0; n < 4 && !i; n++) { c = c.parentElement; i = c && c.querySelector('input,textarea') } return { value: i ? i.value : null, top: Math.round(l.getBoundingClientRect().top) } })
const order = (p) => p.evaluate(() => [...document.querySelectorAll('label')].filter((x) => x.getClientRects().length).map((x) => x.textContent.trim()))
const fill = async (p) => { const b = p.locator('button:visible', { hasText: /^Fill empty fields$/ }).first(); const on = await b.isEnabled({ timeout: 3000 }).catch(() => false); if (on) { await b.click({ timeout: 4000 }).catch(() => {}); await p.waitForTimeout(2500) } return on }
const text = (p) => p.evaluate(() => document.body.textContent.replace(/\s+/g, ' '))

// B1 the box, always there, in its place
{
  const { ctx, p, st } = await openBuilder(1440, undefined)
  const o = await order(p)
  ok(o.indexOf('Light switches') === o.indexOf('Best way in') + 1 && o.indexOf('Best way in') > -1, '1440: the Access card has Light switches right after Best way in', o)
  const at = await p.evaluate(() => { const t = document.body.innerText; return [t.indexOf('Best way in'), t.indexOf('Light switches'), t.indexOf('Obstacles')] })
  ok(at[0] < at[1], '1440: and before what follows', at)
  ok(st.errors.length === 0, '1440: no page errors', st.errors)
  await ctx.close()
}
// B2 a form that answered it: the rail shows it, Fill empty fields takes it into the draft
{
  const { ctx, p } = await openBuilder(1440, ANSWER)
  const t = await text(p)
  ok(t.includes(ANSWER), '1440: the side by side offers the form\'s answer')
  await p.screenshot({ path: `${out}/builder_1440.png` }).catch(() => {})
  const on = await fill(p)
  ok(on && (await draftFact(p)) === ANSWER, '1440: Fill empty fields writes it to the draft', { on, draft: await draftFact(p) })
  const b = await box(p)
  ok(!!b && b.value === ANSWER, '1440: the box shows it', b)
  await p.evaluate(() => { const l = [...document.querySelectorAll('label')].find((x) => x.getClientRects().length && x.textContent.trim().startsWith('Light switches')); l && l.scrollIntoView({ block: 'center' }) })
  await p.waitForTimeout(300)
  await p.screenshot({ path: `${out}/builder_filled_1440.png` }).catch(() => {})
  await ctx.close()
}
// B3 never over a value already on the page
{
  const { ctx, p } = await openBuilder(1440, ANSWER, 'Already typed by the office')
  await fill(p)
  const b = await box(p)
  ok(!!b && b.value === 'Already typed by the office', '1440: Fill empty fields leaves a value already on the page', b)
  await ctx.close()
}
// B4 an older form, or equipment outside: not on the form, nothing to fill
{
  const { ctx, p } = await openBuilder(1440, undefined)
  const L = await p.evaluate(() => [...document.querySelectorAll('p')].map((x) => x.textContent.replace(/\s+/g, ' ').trim()).filter((t) => /^Not on the form: /.test(t)))
  const rail = await p.evaluate(() => { const e = [...document.querySelectorAll('*')].filter((x) => x.children.length < 3 && /Light switches/.test(x.textContent) && x.parentElement && x.getClientRects().length).map((x) => x.parentElement.textContent.replace(/\s+/g, ' ').slice(0, 90)); return [...new Set(e)].slice(0, 8) })
  console.log('INFO where Light switches shows when the form has no answer:', JSON.stringify(rail))
  ok(!(await text(p)).includes('Fills Light switches'), '1440: a form that never asked offers nothing for Light switches', L)
  await fill(p)
  ok((await draftFact(p)) == null, '1440: and nothing is filled', await draftFact(p))
  await ctx.close()
}
// S the Site file, public route, phone and desktop
const reply = (val) => { const c = clone(row.pb.live.content); c.facts = c.facts || {}; delete c.facts.light_switches; if (val) c.facts.light_switches = val; return { ok: true, property: row.pb.property, version: 1, approved_at: row.pb.live.approved_at || '2026-11-06T12:00:00Z', approved_by: 'Fred', content: c, photos: [], photos_unavailable: 0, sign_failures: 0 } }
const rows = (p) => p.evaluate(() => { const t = document.body.innerText; return { has: /Light switches/.test(t), all: t.replace(/\s+/g, ' ').slice(0, 900) } })
for (const w of [390, 1280]) {
  const { ctx, p, st } = await open(w, '/driver#code=' + FAKE, {}, () => /Access/.test(document.body.textContent), reply(ANSWER))
  const a = await rows(p)
  ok(a.has && a.all.includes(ANSWER), `${w}: the Site file shows the Light switches row and its answer`, a.has)
  const seq = ['Best way in', 'Light switches', 'Obstacles'].map((x) => a.all.indexOf(x))
  ok(seq[1] > -1 && (seq[0] === -1 || seq[0] < seq[1]) && (seq[2] === -1 || seq[1] < seq[2]), `${w}: in its place`, seq)
  await p.evaluate(() => { const e = [...document.querySelectorAll('*')].find((x) => x.children.length === 0 && x.textContent.trim() === 'Light switches'); e && e.scrollIntoView({ block: 'center' }) })
  await p.waitForTimeout(300)
  await p.screenshot({ path: `${out}/site_${w}.png` }).catch(() => {})
  ok(st.errors.length === 0, `${w}: no page errors`, st.errors)
  await ctx.close()
  const n = await open(w, '/driver#code=' + FAKE, {}, () => /Access/.test(document.body.textContent), reply(null))
  ok(!(await rows(n.p)).has, `${w}: with no answer there is no row`)
  await n.ctx.close()
}
await browser.close()
// D the database's own page rule takes the fact. Nothing is written: the rule only reads, and the transaction is thrown away.
// The smallest page it accepts; the facts rule treats every key the same, so a second row with a wrong value is the control.
const rule = async (facts) => { const t = await raw(`begin; do $x$ declare m text; begin m := public.fn_page_content_problem(1164, $q$${JSON.stringify({ v: 1, facts, photos: [] })}$q$::jsonb); raise exception 'RULE:%', coalesce(m, 'accepted'); end $x$;`); return (t.text.match(/RULE:[^\\"]*/) || [t.text.slice(0, 200)])[0] }
const good = await rule({ light_switches: ANSWER })
ok(good === 'RULE:accepted', 'the database page rule accepts light_switches', good)
const bad = await rule({ light_switches: true })
ok(/short text/.test(bad), 'control: the same rule refuses a true/false in that fact', bad)
console.log(`${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
