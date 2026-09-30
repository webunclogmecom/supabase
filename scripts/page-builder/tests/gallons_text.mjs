// LIVE Picture Planner, parts G and T of the T2 plan: the site survey form's version 2 asks "Gallons" as a TEXT box under
// the same key grease_trap.capacity_gallons (Fred, 2026-09-29: "Gallons" and "Measurements" "both are texts"; his rule: a
// plain whole number still flows to the property, any other text is shown only, never offered). The server's rule (T1,
// public.fn_intake_whole_gallons + get_intake_compare): trimmed, optional thousands commas, an optional trailing "gal" or
// "gallons" (any case; the singular "gallon" is not in it), at most 6 digits, and 1 to 20,000; anything else is the
// compare state not_savable. G: the Page Builder's formToPage reads a text answer with that rule, says why it left one
// out, and does not call a left-out answer "Not on the form". T: the Property record tab shows a not_savable row grey,
// with the text as plain text and a note, and no tick. Real replies read as Fred's claims, then edited per scenario;
// sign-in faked, every RPC stubbed, Google Maps aborted. Nothing is written. Codes are never printed.
// Spec: Building Apps/Picture Planner/docs/specs/2026-09-29-pin-warning-map-fit-design.md, section 7
//   node scripts/page-builder/tests/gallons_text.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms, client.get_intake(715) as i715, client.get_intake_compare(715) as c715,
       (select jsonb_agg(to_jsonb(s) order by s.submitted_at desc) from client.v_intake_submissions s where s.property_id = 1164 and s.state = 'submitted') as subs;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
if (!row || !row.pb || !row.pb.live || !Array.isArray(row.forms) || !row.forms.length || !row.c715 || !Array.isArray(row.c715.fields)) { console.log('FAIL fixture: 1164 needs a live version and a submitted form, and form 715 its compare :: ' + ((r && r.message) || Object.keys(row || {}))); process.exit(1) }  // never the raw reply: it holds codes
const clone = (x) => JSON.parse(JSON.stringify(x))
const GKEY = 'grease_trap.capacity_gallons'
const KEYS = ['access_entry.lock_box_code', 'access_hours.schedule', GKEY, 'grease_trap.manhole_count', 'grease_trap.sample_ports']
const SENT = (t) => `Gallons: "${t}" is not a whole number of gallons from 1 to 20,000. Type it on the page.`
const NOTE = 'Not a whole number of gallons from 1 to 20,000, so it cannot be saved here.'
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 300)}`) }
// the builder: the live version with one grease trap system and no gallons (so NEEDS lets gallons fill), every form
// answering systems 1 and the gallons value of the scenario (undefined = the answer removed)
const builder = (gal) => {
  const d = { pb: clone(row.pb), forms: clone(row.forms) }
  d.pb.pending = null
  d.pb.property.source = clone(d.pb.live.source)   // no "Changed in the Client App's property data" notice
  const f = (d.pb.live.content.facts = d.pb.live.content.facts || {}); f.gt_systems = 1; delete f.gallons
  for (const fm of d.forms) { fm.answers = fm.answers || {}; fm.answers['grease_trap.systems_count'] = 1; if (gal === undefined) delete fm.answers[GKEY]; else fm.answers[GKEY] = gal }
  return d
}
// the tab: form 715, the other four rows blank (ticked), the gallons row not_savable
const tab = () => {
  const c = clone(row.c715); c.can_accept = true; c.accept_blocker = null
  for (const f of c.fields) if (KEYS.includes(f.key)) { f.ours = null; f.state = 'blank' }
  const g = c.fields.find((f) => f.key === GKEY); if (g) { g.state = 'not_savable'; g.theirs = 'about 1000'; g.ours = 30 }
  const i = clone(row.i715); i.accepted = []
  return { cmp: c, intake: i }
}
const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './gallons_text_shots'; fs.mkdirSync(out, { recursive: true })
const subHits = []
async function open(w, path, replies, ready) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { calls: [], errors: [] }
  p.on('pageerror', (e) => { if (!/Google Maps/.test(String(e))) st.errors.push(String(e)) })
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n); if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) }); return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' }) })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route(SB + '/functions/v1/**', (x) => x.abort())
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  await p.route('https://places.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + path)
  await p.waitForFunction(ready, null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(3000)
  return { ctx, p, st }
}
const openBuilder = (w, gal) => { const d = builder(gal); return open(w, '/property/1164', { get_page_builder: d.pb, get_page_builder_forms: d.forms, get_property_activity: [], get_page_versions: [] }, () => [...document.querySelectorAll('h3')].some((h) => h.textContent === 'Contacts')) }
const body = (p) => p.evaluate(() => document.body.textContent.replace(/\s+/g, ' '))
const draftGallons = (p) => p.evaluate(() => { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k.startsWith('pp-draft:')) { try { const f = JSON.parse(localStorage.getItem(k)).content.facts || {}; return 'gallons' in f ? f.gallons : null } catch { return 'bad' } } } return null })
const fill = async (p) => { const b = p.locator('button', { hasText: /^Fill empty fields$/ }).first(); const on = await b.isEnabled({ timeout: 3000 }).catch(() => false); if (on) { await b.click({ timeout: 4000 }).catch(() => {}); await p.waitForTimeout(2500) } return on }

// G1 to G3: a whole number is offered as that number (text with the server's rule; a plain number and an old number as today)
for (const [name, gal, want] of [['a text "1,500 gal" answer fills Gallons as 1500', '1,500 gal', 1500], ['guard, a plain "30" still fills Gallons as 30', '30', 30], ['guard, an old number answer (30) still fills Gallons as 30', 30, 30]]) {
  const { ctx, p, st } = await openBuilder(1024, gal)
  const on = await fill(p)
  const g = await draftGallons(p)
  ok(on && g === want, `1024: ${name}`, { fillEnabled: on, draftGallons: g, errors: st.errors })
  await ctx.close()
}
// G4 to G8: any other text is left out, with its sentence, and never filled
for (const [name, gal] of [['prose "about 1000"', 'about 1000'], ['a decimal "30.5"', '30.5'], ['"0" (out of range)', '0'], ['"25,000 gal" (out of range)', '25,000 gal'], ['the singular "1000 gallon"', '1000 gallon']]) {
  const { ctx, p } = await openBuilder(1024, gal)
  const said = (await body(p)).includes(SENT(gal))
  await fill(p)
  const g = await draftGallons(p)
  ok(said && g == null, `1024: ${name} is left out with "${SENT(gal)}" and never filled`, { sentence: said, draftGallons: g })
  if (gal === 'about 1000') await p.screenshot({ path: `${out}/G_prose_1024.png`, fullPage: false }).catch(() => {})
  await ctx.close()
}
// G9, G10: from 1280px the side by side's "Not on the form" line names only what the form truly lacks
const notOnForm = (p) => p.evaluate(() => [...document.querySelectorAll('p')].map((x) => x.textContent.replace(/\s+/g, ' ').trim()).filter((t) => /^Not on the form: /.test(t)))
{
  const { ctx, p } = await openBuilder(1440, 'about 1000')
  const L = await notOnForm(p)
  ok(!L.some((t) => /\bGallons\b/.test(t)), '1440: "about 1000" is not listed under "Not on the form" (the form has an answer)', L)
  await ctx.close()
}
{
  const { ctx, p } = await openBuilder(1440, undefined)
  const L = await notOnForm(p)
  ok(L.some((t) => /\bGallons\b/.test(t)), '1440: guard, a form with no gallons answer at all lists Gallons under "Not on the form"', L)
  await ctx.close()
}
// T: the Property record tab, form 715, at 390
{
  const d = tab()
  const { ctx, p, st } = await open(390, '/forms/715', { get_intake: d.intake, get_intake_compare: d.cmp, v_intake_submissions: row.subs || [] }, () => /answered|Waiting for the collector|Cancelled/.test(document.body.textContent))
  await p.getByRole('tab', { name: 'Property record' }).click({ timeout: 5000 }).catch(() => {})
  await p.waitForFunction(() => document.querySelectorAll('[data-accept-row]').length === 5, null, { timeout: 15000 }).catch(() => {})
  await p.waitForTimeout(500)
  const R = await p.evaluate(([gk]) => [...document.querySelectorAll('[data-accept-row]')].map((el) => {
    const side = el.querySelector('[data-side="form"]'), note = el.querySelector('[data-accept-note]'), cb = el.querySelector('[role="checkbox"]')
    return { key: el.getAttribute('data-accept-row'), cls: el.className, form: side ? side.textContent.replace(/\s+/g, ' ').trim() : null,
      chip: !!(side && [...side.querySelectorAll('*')].some((c) => /rgba\(241,71,20,0\.35\)/.test(String(c.className)))), svg: !!(side && side.querySelector('svg')),
      note: note ? note.textContent.replace(/\s+/g, ' ').trim() : null, cb: cb ? cb.getAttribute('aria-checked') : null }
  }), [GKEY])
  const g = R.find((x) => x.key === GKEY)
  ok(!!g && /\bbg-\[#f4f4f5\]/.test(g.cls) && !/\bbg-white\b/.test(g.cls), '390: the not_savable gallons row is grey, like same and not_shown', g && g.cls)
  ok(!!g && !g.chip && !g.svg && !!g.form && g.form.startsWith('about 1000') && g.note === NOTE, `390: it shows "about 1000" as plain text (no arrow chip) and "${NOTE}"`, g && { form: g.form, chip: g.chip, svg: g.svg, note: g.note })
  ok(!!g && g.cb === null, '390: guard, the not_savable row has no tick', g && g.cb)
  ok(R.length === 5 && R.filter((x) => x.key !== GKEY).every((x) => x.cb === 'true' && !x.note), '390: guard, the other four rows are blank, ticked, and carry no note', R.map((x) => [x.key, x.cb, !!x.note]))
  await p.screenshot({ path: `${out}/T_390.png`, fullPage: true }).catch(() => {})
  ok(st.errors.length === 0, '390: guard, no page errors on the tab', st.errors)
  await ctx.close()
}
await browser.close()
if (process.env.CHUNK_SUB) console.log(`CHUNK_SUB edits applied: ${new Set(subHits).size} of ${process.env.CHUNK_SUB.split('@@@').length}`)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
