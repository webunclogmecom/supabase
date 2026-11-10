// LIVE Ops Portal Page Builder /planner/property/1164: Fred's pick A3a (2026-11-10, "A3a: under each field"). Where the
// site survey's answer differs from the page, or the page is empty, "Site survey says" sits UNDER the field at every width,
// with Use this; where the two agree the field carries the "Same as the site survey" tick. The portal has no side by side
// panel, so this file is what tests the survey's answers there (the old host's panel is tested by hours_mirror,
// lift_water_sections B9, reject_counts, gallons_text G9/G10, map_draft F2b).
// Two fields stand for all of them: the hours card (When we can come) and a text fact (Light switches).
// Real replies read in SQL as Fred's claims, edited per scenario; sign-in faked; every call stubbed; nothing written.
// Lock box / gate codes are masked in the output.
//   PLANNER_BASE=https://ops.unclogme.app/planner node scripts/page-builder/tests/survey_under_field.mjs <outdir>
//   Control: CHUNK_SUB='data-survey-says|||data-survey-x' must FAIL every "under the field" check.
import fs from 'node:fs'
import { createRequire } from 'node:module'
import { H, R, PORTAL, seedSession, routeCode } from './host.mjs'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
if (!PORTAL) { console.log('SKIP: the old host shows the survey in its side by side panel from 1280px; set PLANNER_BASE to the portal'); process.exit(0) }
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
if (!row || !row.pb || !row.pb.live || !Array.isArray(row.forms) || !row.forms.length) { console.log('FAIL fixture: 1164 needs a live version and a submitted form :: ' + ((r && r.message) || Object.keys(row || {}))); process.exit(1) }
const clone = (x) => JSON.parse(JSON.stringify(x))
const SECRETS = [...new Set([row.pb.property?.source?.lock_box_key, row.pb.link?.public_id,
  ...[row.pb.live, row.pb.pending].filter(Boolean).flatMap((v) => ['lock_box_code', 'gate_code', 'key_tag'].map((k) => v.content?.facts?.[k])),
  ...row.forms.flatMap((f) => ['access_entry.lock_box_code', 'access_entry.gate_code'].map((k) => f.answers?.[k]))]
  .filter((s) => s != null && String(s).trim().length >= 3).map(String))]
const mask = (s) => SECRETS.reduce((t, x) => t.split(x).join('<code>'), String(s))
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + mask(JSON.stringify(v)).slice(0, 400)}`) }

// scenarios: the page's hours and light switches (the live version's content) against the chosen form's (forms[0])
const W = (days, open, close) => Object.fromEntries(days.map((d) => [d, { open, close }]))
const PAGE_H = { ...W(['mon', 'wed', 'thu', 'fri', 'sat'], '22:00', '06:00'), tue: { open: '09:00', close: '17:00' } }
const FORM_H = { ...W(['mon', 'wed', 'thu', 'fri', 'sat'], '22:00', '06:00'), tue: { open: '21:00', close: '05:00' } }
const LS = 'Behind the walk-in door, on the left', LS_PAGE = 'By the back door', LS_KEY = 'access_entry.light_switches'
const make = (pageHours, formHours, pageLs, formLs) => {
  const d = { pb: clone(row.pb), forms: clone(row.forms) }
  d.pb.pending = null
  d.pb.property.source = clone(d.pb.live.source)   // no property record notice
  d.pb.live.content.hours = pageHours
  const f = (d.pb.live.content.facts = d.pb.live.content.facts || {}); delete f.light_switches; if (pageLs) f.light_switches = pageLs
  for (const fm of d.forms) { fm.answers = fm.answers || {}; delete fm.answers[LS_KEY]; if (formLs !== undefined) fm.answers[LS_KEY] = formLs }
  d.forms[0].answers['access_hours.schedule'] = formHours
  return d
}
const SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const READS = ['get_my_access', 'portal_waiting', 'get_page_builder', 'get_page_builder_forms', 'get_property_activity', 'get_page_versions']
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './survey_shots'; fs.mkdirSync(out, { recursive: true })
async function open(w, data) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await seedSession(ctx, session, user)
  const p = await ctx.newPage()
  const st = { calls: [], errors: [] }
  p.on('pageerror', (e) => { if (!/Google Maps|google is not defined/.test(String(e))) st.errors.push(String(e)) })
  const replies = { get_page_builder: data.pb, get_page_builder_forms: data.forms, get_property_activity: [], get_page_versions: [], portal_waiting: {}, get_my_access: { employee_id: 1, group: 'admin', me: { full_name: 'Visual Check', color_hex: null, photo_path: null }, apps: [{ app: 'picture_planner', name: 'Picture Planner', parent: null, mode: 'on', level: 'edit' }] } }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n); if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) }); return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' }) })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route(SB + '/functions/v1/**', (x) => { st.calls.push('fn:' + new URL(x.request().url()).pathname.split('/').pop()); return x.abort() })
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  await p.route('https://places.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await routeCode(p, async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) t = t.split(from).join(to); return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + R + '/property/1164')
  await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent.trim().startsWith('When we can come')), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(2500)
  return { ctx, p, st }
}
// one read of both fields: the survey line under each, its Use this, the tick, and the field's value
const read = (p) => p.evaluate(() => {
  const line = (box) => { const s = box && box.querySelector('[data-survey-says]'); if (!s) return null; const b = s.querySelector('button'); const r = b && b.getBoundingClientRect(); return { text: s.textContent.replace(/\s+/g, ' ').trim(), aria: b && b.getAttribute('aria-label'), h: r ? Math.round(r.height) : 0, inside: !!box && box.contains(s) } }
  const tick = (el) => !!el && !!el.querySelector('[title="Same as the site survey"]')
  const h3 = [...document.querySelectorAll('h3')].find((h) => h.textContent.trim().startsWith('When we can come'))
  const card = h3 && h3.parentElement
  const lab = [...document.querySelectorAll('label')].find((l) => l.textContent.trim() === 'Light switches')
  const fact = lab && lab.closest('div')
  const input = lab && document.getElementById(lab.htmlFor)
  const tue = document.querySelector('input[aria-label="Tue opens"]')
  return {
    panel: document.querySelectorAll('section[aria-label="When we can come on the form"], [data-hours-mirror], [data-hours-chip]').length,
    hours: { found: !!card, line: line(card), tick: tick(h3), tue: tue ? tue.value : null },
    ls: { found: !!fact, line: line(fact), tick: tick(lab && lab.parentElement), value: input ? input.value : null, labelOnly: lab ? lab.textContent.trim() : null },
    lines: document.querySelectorAll('[data-survey-says]').length,
    sideways: document.documentElement.scrollWidth > innerWidth,
  }
})
const nothingWritten = (st) => st.calls.filter((n) => !READS.includes(n))

for (const w of [1440, 1280, 390]) {
  const phone = w < 768, minH = phone ? 44 : 28
  // A. both differ
  {
    const { ctx, p, st } = await open(w, make(PAGE_H, FORM_H, LS_PAGE, LS))
    const a = await read(p)
    ok(a.panel === 0, `${w} A: no side by side panel`, a.panel)
    ok(a.hours.found && !!a.hours.line && a.hours.line.inside, `${w} A: the hours card has the survey line under it`, a.hours.line)
    ok(!!a.hours.line && /Differs/.test(a.hours.line.text) && /Site survey says/.test(a.hours.line.text) && /9:00 PM/.test(a.hours.line.text), `${w} A: it says Differs and shows the form's Tue 9:00 PM`, a.hours.line && a.hours.line.text)
    ok(!!a.hours.line && a.hours.line.aria === "Use the site survey's When we can come" && a.hours.line.h >= minH, `${w} A: its Use this is named for the field and ${minH}px or taller`, a.hours.line && { aria: a.hours.line.aria, h: a.hours.line.h })
    ok(!a.hours.tick, `${w} A: no Same tick on the hours while they differ`)
    ok(a.ls.found && !!a.ls.line && a.ls.line.inside && a.ls.line.text.includes(LS) && /Differs/.test(a.ls.line.text), `${w} A: Light switches has the form's answer under it`, a.ls.line && a.ls.line.text)
    ok(a.ls.labelOnly === 'Light switches', `${w} A: the field's label names the field only`, a.ls.labelOnly)
    ok(!a.sideways, `${w} A: no sideways scroll`)
    await p.screenshot({ path: `${out}/A_${w}.png`, fullPage: false }).catch(() => {})
    // Use this, hours then light switches
    await p.getByRole('button', { name: "Use the site survey's When we can come" }).click({ timeout: 4000 }).catch(() => {}); await p.waitForTimeout(500)
    const b = await read(p)
    ok(b.hours.tue === '21:00' && !b.hours.line && b.hours.tick, `${w} A: Use this puts the form's hours in, the line goes and the Same tick shows`, b.hours)
    await p.getByRole('button', { name: "Use the site survey's Light switches" }).click({ timeout: 4000 }).catch(() => {}); await p.waitForTimeout(500)
    const c = await read(p)
    ok(c.ls.value === LS && !c.ls.line && c.ls.tick, `${w} A: Use this puts the form's light switches in, the line goes and the Same tick shows`, c.ls)
    ok(nothingWritten(st).length === 0, `${w} A: nothing written`, nothingWritten(st))
    ok(st.errors.length === 0, `${w} A: no page errors`, st.errors)
    await ctx.close()
  }
  // B. both the same: a tick, no line
  {
    const { ctx, p } = await open(w, make(FORM_H, FORM_H, LS, LS))
    const a = await read(p)
    ok(a.hours.found && !a.hours.line && a.hours.tick, `${w} B: same hours: the tick, no survey line`, a.hours)
    ok(a.ls.found && !a.ls.line && a.ls.tick, `${w} B: same light switches: the tick, no survey line`, a.ls)
    await ctx.close()
  }
}
// C. the page is empty: the line says Empty here
{
  const { ctx, p } = await open(1440, make({}, FORM_H, null, LS))
  const a = await read(p)
  ok(!!a.hours.line && /Empty here/.test(a.hours.line.text), '1440 C: empty hours: the line says Empty here', a.hours.line && a.hours.line.text)
  ok(!!a.ls.line && /Empty here/.test(a.ls.line.text) && a.ls.value === '', '1440 C: empty light switches: the line says Empty here', a.ls)
  await ctx.close()
}
await browser.close()
console.log(`=== ${pass} pass, ${fail} fail`)
process.exit(fail ? 1 : 0)
