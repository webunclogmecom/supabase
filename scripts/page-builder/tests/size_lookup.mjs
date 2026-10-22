// LIVE Picture Planner /forms/1047: the AI lookup of a grease trap's gallons (Trello 6t3RDVkE, 2026-10-22). Real replies
// for form 1047 read as Fred's claims, then edited per scenario: the lookup states and the offer are stubbed, so the test
// never depends on what the lookup table holds. Sign-in faked; every call stubbed; Save is RECORDED, nothing is written.
// Spec: Building Apps/Picture Planner/docs/specs/2026-10-22-grease-trap-model-lookup-design.md
//   node scripts/page-builder/tests/size_lookup.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@...' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_intake(1047) as i, client.get_intake_compare(1047) as c,
       (select jsonb_agg(to_jsonb(s)) from client.v_intake_submissions s where s.intake_id = 1047) as subs;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
if (!row || !row.i || !('size_lookups' in row.i)) { console.log('FAIL fixture: get_intake has no size_lookups (part 1 not applied?) :: ' + ((r && r.message) || '')); process.exit(1) }
const clone = (x) => JSON.parse(JSON.stringify(x))
const MEAS = row.i.sections.flatMap((s) => s.questions).find((q) => q.key === 'grease_trap.capacity_measure')
if (!MEAS || !MEAS.value) { console.log('FAIL fixture: form 1047 must answer the measurements'); process.exit(1) }
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 400)}`) }

const L = (o) => ({ key: 'grease_trap.capacity_measure', kind: 'measurements', input_text: MEAS.value, status: 'found', gallons: 3142, summary: '180 x 48 x 84 in: 3,142 gallons (length x width x depth / 231).', brand: null, model: null, dimensions: '180 x 48 x 84 in', source_url: null, looked_up_at: new Date().toISOString(), ...o })
// the measurements question turned into a model question (the form of question list version 5), in the stubbed reply only
const asModel = (i, answer) => { const x = clone(i); for (const s of x.sections) for (const q of s.questions) if (q.key === 'grease_trap.capacity_measure') { q.key = 'grease_trap.model'; q.label = 'Grease trap model'; q.value = answer } return x }
const intake = (lookups, model = null) => { const x = model ? asModel(row.i, model) : clone(row.i); x.size_lookups = lookups; x.accepted = []; return x }
const cmp = (offer) => { const c = clone(row.c); c.can_accept = true; c.accept_blocker = null; for (const f of c.fields) if (f.key === 'grease_trap.capacity_gallons') { f.ours = null; if (offer) { f.theirs = offer.gallons; f.state = 'blank'; f.offer = offer } else { f.theirs = null; f.state = 'unanswered'; delete f.offer } } return c }
const SRC = 'https://www.schierproducts.com/shop/gb-75'
const OFFER_M = { gallons: 3142, kind: 'measurements', input_text: MEAS.value, summary: '180 x 48 x 84 in: 3,142 gallons (length x width x depth / 231).', source_url: null, lookup_id: 1 }
const OFFER_G = { gallons: 125, kind: 'model', input_text: 'Schier GB-75', summary: 'The Schier GB-75 holds 125 gallons.', source_url: SRC, lookup_id: 2 }

const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp, user }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './size_lookup_shots'; fs.mkdirSync(out, { recursive: true })
async function open(w, I, C) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { calls: [], bodies: [], errors: [] }
  p.on('pageerror', (e) => st.errors.push(String(e)))
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => {
    const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n)
    let b = {}; try { b = JSON.parse(x.request().postData() || '{}') } catch {}
    const send = (v) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(v) })
    if (n === 'accept_intake_answers') { st.bodies.push(b); return send({ ok: true, intake_id: b.p_intake_id, accepted: b.p_keys }) }
    if (n === 'get_intake') return send(I)
    if (n === 'get_intake_compare') return send(C)
    if (n === 'v_intake_submissions') return send(row.subs)
    if (n === 'get_my_access') return send({ ok: true })
    return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' })
  })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [a, c] of pairs) t = t.split(a).join(c); await x.fulfill({ status: 200, contentType: 'application/javascript', body: t }) }) }
  await p.goto(H + '/forms/1047')
  await p.waitForFunction(() => /answered/.test(document.body.textContent), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(2000)
  return { ctx, p, st }
}
const boxes = (p) => p.evaluate(() => [...document.querySelectorAll('[data-size-lookup]')].map((b) => {
  const row = b.closest('.py-2'); const a = b.querySelector('a')
  return { status: b.getAttribute('data-size-lookup'), text: b.textContent.replace(/\s+/g, ' ').trim(), rowLabel: row ? (row.firstElementChild || {}).textContent : null,
    link: a ? { text: a.textContent.trim(), href: a.getAttribute('href'), target: a.getAttribute('target'), rel: a.getAttribute('rel') } : null, clickables: b.querySelectorAll('a,button,[role="button"],input').length }
}))
const offerLine = (p) => p.evaluate(() => { const r = document.querySelector('[data-accept-row="grease_trap.capacity_gallons"]'); if (!r) return null; const o = r.querySelector('[data-ai-offer]'); const f = r.querySelector('[data-side="form"]'); const a = f && f.querySelector('a'); return { offer: o ? o.textContent.replace(/\s+/g, ' ').trim() : null, form: f ? f.textContent.replace(/\s+/g, ' ').trim() : null, link: a ? { text: a.textContent.trim(), href: a.getAttribute('href'), target: a.getAttribute('target'), rel: a.getAttribute('rel') } : null } })
const sideways = (p) => p.evaluate(() => document.documentElement.scrollWidth > innerWidth)
const toRecord = async (p) => { await p.getByRole('tab', { name: 'Property record' }).click({ timeout: 5000 }).catch(() => {}); await p.waitForFunction(() => document.querySelectorAll('[data-accept-row]').length > 0, null, { timeout: 15000 }).catch(() => {}); await p.waitForTimeout(500) }

for (const w of [390, 1280]) {
  // A. measurements found: the box under the Measurements answer, then the Property record row says where 3,142 came from
  let { ctx, p, st } = await open(w, intake([L({})]), cmp(OFFER_M))
  let B = await boxes(p)
  ok(B.length === 1 && B[0].status === 'found' && /^Measurements/.test(B[0].rowLabel || ''), `${w}: A, one box, under the Measurements answer`, B.map((b) => [b.status, b.rowLabel]))
  ok(B.length === 1 && B[0].text.startsWith('AI lookup') && B[0].text.includes('3,142 gallons') && B[0].text.includes(OFFER_M.summary) && B[0].text.endsWith('Save it to the property on the Property record tab.'), `${w}: A, its texts`, B[0] && B[0].text)
  ok(B.length === 1 && !B[0].link && B[0].clickables === 0, `${w}: A, nothing clickable and no source for measurements`)
  ok(!(await sideways(p)), `${w}: A, no sideways scroll`)
  ok(!st.calls.includes('accept_intake_answers'), `${w}: A, the Answers tab writes nothing`)
  await p.locator('[data-size-lookup]').first().scrollIntoViewIfNeeded().catch(() => {}); await p.screenshot({ path: `${out}/A_answers_${w}.png` })
  await toRecord(p)
  let O = await offerLine(p)
  ok(O && O.offer === 'From the AI lookup of the measurements' && O.form.includes(OFFER_M.summary) && !O.link, `${w}: A, the Gallons row says it came from the measurements`, O)
  await p.locator('[data-accept-row="grease_trap.capacity_gallons"]').scrollIntoViewIfNeeded().catch(() => {}); await p.screenshot({ path: `${out}/A_record_${w}.png` })
  // Save is the same call with the same three arguments; the number is never sent
  const save = p.getByRole('button', { name: /^Save \d+ changes? to the property$/ })
  await save.click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(400)
  await p.getByRole('button', { name: /^Save \d+ changes?$/ }).click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(2000)
  const body = st.bodies[0]
  ok(!!body && Object.keys(body).sort().join() === 'p_expected,p_intake_id,p_keys' && body.p_intake_id === 1047 && body.p_keys.includes('grease_trap.capacity_gallons') && body.p_expected['grease_trap.capacity_gallons'] === null && !JSON.stringify(body).includes('3142'), `${w}: A, Save sends p_intake_id, p_keys, p_expected only (no gallons number)`, body)
  ok(st.errors.length === 0, `${w}: A, no page errors`, st.errors)
  await ctx.close()

  // B. a model found: the source link (hostname, new tab, noopener), the check sentence; text stays text
  ;({ ctx, p, st } = await open(w, intake([L({ key: 'grease_trap.model', kind: 'model', input_text: 'Schier GB-75', gallons: 125, model: 'GB-75', dimensions: '33 in W x 47 in D x 40 in H', summary: 'The Schier GB-75 holds <b>125</b> gallons.', source_url: SRC })], 'Schier GB-75'), cmp(OFFER_G)))
  B = await boxes(p)
  ok(B.length === 1 && B[0].status === 'found' && /^Grease trap model/.test(B[0].rowLabel || ''), `${w}: B, under the model answer`, B.map((b) => b.rowLabel))
  ok(B.length === 1 && B[0].text.includes('125 gallons') && B[0].text.includes('GB-75 · 33 in W x 47 in D x 40 in H') && B[0].text.includes('The Schier GB-75 holds <b>125</b> gallons.') && B[0].text.endsWith('Check the source before saving it to the property.'), `${w}: B, its texts (the summary as plain text)`, B[0] && B[0].text)
  ok(B.length === 1 && B[0].link && B[0].link.text === 'Source: schierproducts.com' && B[0].link.href === SRC && B[0].link.target === '_blank' && /noopener/.test(B[0].link.rel || '') && /noreferrer/.test(B[0].link.rel || '') && B[0].clickables === 1, `${w}: B, one link: Source: schierproducts.com in a new tab`, B[0] && B[0].link)
  await p.locator('[data-size-lookup]').first().scrollIntoViewIfNeeded().catch(() => {}); await p.screenshot({ path: `${out}/B_answers_${w}.png` })
  await toRecord(p)
  O = await offerLine(p)
  ok(O && O.offer === 'From the AI lookup of Schier GB-75' && O.link && O.link.text === 'Source: schierproducts.com' && O.link.target === '_blank' && /noopener/.test(O.link.rel || ''), `${w}: B, the Gallons row names the model and links the source`, O)
  ok(!(await sideways(p)), `${w}: B, no sideways scroll`)
  await p.locator('[data-accept-row="grease_trap.capacity_gallons"]').scrollIntoViewIfNeeded().catch(() => {}); await p.screenshot({ path: `${out}/B_record_${w}.png` })
  await ctx.close()

  // C. the other states, and a source that is not a web page gets no link
  ;({ ctx, p, st } = await open(w, intake([L({ key: 'grease_trap.model', kind: 'model', status: 'not_found', gallons: null, summary: 'Only 25 GPM and 56.4 lb are published.' })], 'Thermaco Big Dipper W-250-IS'), cmp(null)))
  B = await boxes(p)
  ok(B.length === 1 && B[0].status === 'not_found' && B[0].text.replace(/\s/g, '') === 'AIlookupTheAIcouldnotfindthegallonsforthismodel.Only25GPMand56.4lbarepublished.', `${w}: C, model not found`, B[0] && B[0].text)
  ok(!(await offerLine(p).then((o) => o && o.offer)), `${w}: C, no offer, no AI line on the Property record tab (before opening it)`)
  await toRecord(p)
  ok(!((await offerLine(p)) || {}).offer, `${w}: C, a row without an offer has no AI line`)
  await ctx.close()
  ;({ ctx, p } = await open(w, intake([L({ status: 'not_found', gallons: null, summary: 'The depth is missing.' })]), cmp(null)))
  B = await boxes(p)
  ok(B.length === 1 && B[0].text.replace(/\s/g, '') === 'AIlookupTheAIcouldnotreadthegallonsfromthesemeasurements.Thedepthismissing.', `${w}: C, measurements not read`, B[0] && B[0].text)
  await ctx.close()
  ;({ ctx, p } = await open(w, intake([L({ status: 'waiting', gallons: null, summary: null, dimensions: null })]), cmp(null)))
  B = await boxes(p)
  ok(B.length === 1 && B[0].status === 'waiting' && B[0].text.replace(/\s/g, '') === 'AIlookupTheAIlookuphasnotfinishedyet.Itrunsagainwithinthehour.', `${w}: C, waiting`, B[0] && B[0].text)
  await ctx.close()
  ;({ ctx, p } = await open(w, intake([L({ status: 'failed', gallons: null, summary: null })]), cmp(null)))
  B = await boxes(p)
  ok(B.length === 1 && B[0].text.replace(/\s/g, '') === 'AIlookupTheAIlookupfailed3times.Typethegallonsonthepropertybyhand.', `${w}: C, failed`, B[0] && B[0].text)
  await ctx.close()
  ;({ ctx, p } = await open(w, intake([L({ key: 'grease_trap.model', kind: 'model', input_text: 'X', gallons: 125, source_url: 'javascript:alert(1)' })], 'X'), cmp(null)))
  B = await boxes(p)
  ok(B.length === 1 && !B[0].link, `${w}: C, a source that is not http(s) gets no link`, B[0] && B[0].link)
  await ctx.close()

  // D. no lookups at all: nothing new on either tab
  ;({ ctx, p } = await open(w, intake(null), cmp(null)))
  ok((await boxes(p)).length === 0, `${w}: D, no size_lookups, no box`)
  await toRecord(p)
  ok(!((await offerLine(p)) || {}).offer, `${w}: D, no offer, no AI line`)
  await ctx.close()
}
await browser.close()
console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
