// LIVE Page Builder /property/1164: HOURS A (Fred, 2026-09-28). From 1280px the "On the form" panel beside "When we
// can come" is a read-only mirror of the card, one row per day level with the same day on the left (CSS subgrid, no
// script heights). Real replies read in SQL as Fred's claims, hours edited per scenario; sign-in faked; every call
// stubbed; nothing written. Lock box / gate codes are masked in the output.
//   node scripts/page-builder/tests/hours_mirror.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
if (!row || !row.pb || !row.pb.live || !Array.isArray(row.forms) || !row.forms.length) { console.log('FAIL fixture: 1164 needs a live version and a submitted form :: ' + JSON.stringify(r).slice(0, 200)); process.exit(1) }
const clone = (x) => JSON.parse(JSON.stringify(x))
// every code the page could print, masked in anything this script prints
const SECRETS = [...new Set([row.pb.property?.source?.lock_box_key, row.pb.link?.public_id,
  ...[row.pb.live, row.pb.pending].filter(Boolean).flatMap((v) => ['lock_box_code', 'gate_code', 'key_tag'].map((k) => v.content?.facts?.[k])),
  ...row.forms.flatMap((f) => ['access_entry.lock_box_code', 'access_entry.gate_code'].map((k) => f.answers?.[k]))]
  .filter((s) => s != null && String(s).trim().length >= 3).map(String))]
const mask = (s) => SECRETS.reduce((t, x) => t.split(x).join('<code>'), String(s))
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + mask(JSON.stringify(v)).slice(0, 400)}`) }
// scenarios: the page's hours (the live version's content) and the chosen form's answer (forms[0], the default choice)
const W = (days, open, close) => Object.fromEntries(days.map((d) => [d, { open, close }]))
const PAGE = { ...W(['mon', 'tue', 'wed', 'thu', 'sat'], '22:00', '06:00'), fri: { open: '09:00', close: '17:00' } }
const FORM = { ...W(['mon', 'thu', 'fri'], '22:00', '06:00'), tue: { open: '21:00', close: '05:00' }, wed: { open: '08:00', close: '17:00' }, sun: { open: '08:00', close: '12:00' } }
const SAME = W(['mon', 'tue', 'wed', 'thu', 'fri', 'sat'], '22:00', '06:00')
const make = (page, form) => { const d = clone({ pb: row.pb, forms: row.forms }); d.pb.pending = null; d.pb.live.content.hours = page; if (form === null) delete d.forms[0].answers['access_hours.schedule']; else d.forms[0].answers['access_hours.schedule'] = form; return d }
const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './hours_shots'; fs.mkdirSync(out, { recursive: true })
const subHits = []
async function open(w, data) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { calls: [], errors: [] }
  p.on('pageerror', (e) => { if (!/Google Maps/.test(String(e))) st.errors.push(String(e)) })  // Maps is aborted on purpose (no paid tiles)
  const replies = { get_page_builder: data.pb, get_page_builder_forms: data.forms, get_property_activity: [], get_page_versions: [] }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n); if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) }); return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' }) })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  await p.route('https://places.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + '/property/1164')
  await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent === 'Contacts'), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(3500)
  return { ctx, p, st }
}
const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']
const ORANGE = { border: 'rgb(241, 71, 20)', bg: 'rgb(255, 244, 239)', color: 'rgb(201, 58, 15)' }
// one read of both sides of the When we can come pair
const read = (p) => p.evaluate(() => {
  const DN = { mon: 'Mon', tue: 'Tue', wed: 'Wed', thu: 'Thu', fri: 'Fri', sat: 'Sat', sun: 'Sun' }
  const sec = document.querySelector('section[aria-label="When we can come on the form"]')
  const top = (e) => (e ? Math.round(e.getBoundingClientRect().top * 10) / 10 : null)
  const cs = (e) => { if (!e) return null; const s = getComputedStyle(e); return { border: s.borderTopColor, bg: s.backgroundColor, color: s.color, shadow: s.boxShadow, text: e.textContent.trim() } }
  const card = [...document.querySelectorAll('h3')].find((h) => h.textContent.trim() === 'When we can come')
  const cardEl = card ? card.parentElement : null
  const leftChip = cardEl ? cardEl.querySelector('button[aria-pressed]') : null
  const rows = Object.keys(DN).filter((d) => document.querySelector(`input[aria-label="${DN[d]} opens"]`)).map((d) => {
    const li = document.querySelector(`input[aria-label="${DN[d]} opens"]`), lrow = li.parentElement
    const rr = sec ? sec.querySelector(`[data-hours-row="${d}"]`) : null
    const target = rr ? rr.querySelector('[data-hours-open]') || rr.querySelector('[data-hours-none]') : null
    return { d, left: li.value, lTop: top(li), lLabel: top(lrow.firstElementChild), rTop: top(target), rLabel: top(rr && rr.firstElementChild),
      text: rr ? [...rr.children].map((c) => c.textContent.replace(/\s+/g, ' ').trim()).filter(Boolean).join(' ') : null, open: cs(rr && rr.querySelector('[data-hours-open]')), close: cs(rr && rr.querySelector('[data-hours-close]')),
      none: cs(rr && rr.querySelector('[data-hours-none]')), scriptHeight: rr ? rr.style.height || rr.style.minHeight || '' : '' }
  })
  return { present: !!sec, mirrorAttr: !!(sec && sec.hasAttribute('data-hours-mirror')), rows,
    chips: sec ? [...sec.querySelectorAll('[data-hours-chip]')].map((c) => ({ d: c.getAttribute('data-hours-chip'), tag: c.tagName, ...cs(c), top: top(c) })) : [],
    leftChipTop: top(leftChip), leftChipH: leftChip ? Math.round(leftChip.getBoundingClientRect().height) : 0,
    head: sec && sec.firstElementChild ? [...sec.firstElementChild.querySelectorAll('h3,span,button')].map((c) => c.textContent.trim()).join(' ') : '',
    buttons: sec ? [...sec.querySelectorAll('button')].map((b) => b.textContent.replace(/\s+/g, ' ').trim()) : [],
    extra: sec && sec.querySelector('[data-hours-extra]') ? [...sec.querySelector('[data-hours-extra]').children].map((c) => c.textContent.replace(/\s+/g, ' ').trim()).join(' ') : '',
    typable: sec ? sec.querySelectorAll('input,select,textarea,[role="checkbox"],[contenteditable="true"]').length : -1,
    anyRow: document.querySelectorAll('[data-hours-row]').length, anyMirror: document.querySelectorAll('[data-hours-mirror],[data-hours-chip]').length,
    body: sec ? sec.textContent.replace(/\s+/g, ' ') : '' }
})
const level = (R) => R.rows.length > 0 && R.rows.every((x) => x.rTop != null && Math.abs(x.lTop - x.rTop) <= 1 && x.rLabel != null && Math.abs(x.lLabel - x.rLabel) <= 1)
const sideways = (p) => p.evaluate(() => document.documentElement.scrollWidth > innerWidth)
const val = (p, day) => p.evaluate((d) => { const i = document.querySelector(`input[aria-label="${d} opens"]`); return i ? i.value : null }, day)
const isOrange = (b) => !!b && b.border === ORANGE.border && b.bg === ORANGE.bg && b.color === ORANGE.color
const ringed = (c) => !!c && c.shadow && c.shadow !== 'none' && /241, 71, 20/.test(c.shadow)
const onChip = (c) => !!c && c.bg !== 'rgb(255, 255, 255)' && c.bg !== 'rgba(0, 0, 0, 0)'
const footer = (p) => p.evaluate(() => { const f = [...document.querySelectorAll('div')].find((d) => /sticky/.test(d.className) && /bottom-0/.test(d.className)); return f ? { text: f.textContent.replace(/\s+/g, ' '), undo: [...f.querySelectorAll('button')].some((b) => b.textContent.trim() === 'Undo') } : null })
const rowsOf = (R, d) => R.rows.find((x) => x.d === d) || {}
const T12 = { '22:00': '10:00 PM', '06:00': '6:00 AM', '21:00': '9:00 PM', '05:00': '5:00 AM', '08:00': '8:00 AM', '17:00': '5:00 PM', '12:00': '12:00 PM', '09:00': '9:00 AM' }

// A. Page Mon to Sat, form differs (Tue and Wed other times, Fri overnight vs the page's day shift, no Sat, an extra Sun)
for (const w of [1440, 1280]) {
  const { ctx, p, st } = await open(w, make(PAGE, FORM))
  const R = await read(p)
  ok(R.present, `${w}: the "On the form" hours panel is there`)
  ok(R.mirrorAttr, `${w}: the panel is the mirror (data-hours-mirror)`)
  ok(R.chips.length === 7 && R.chips.every((c) => c.tag === 'SPAN') && R.chips.map((c) => c.d).join() === DAYS.join(), `${w}: seven read-only day chips, Mon to Sun`, R.chips.map((c) => [c.d, c.tag]))
  ok(R.chips.length === 7 && DAYS.every((d) => onChip(R.chips.find((c) => c.d === d)) === !!FORM[d]), `${w}: the form's days are filled`, R.chips.map((c) => [c.d, c.bg]))
  ok(R.chips.length === 7 && R.chips.filter(ringed).map((c) => c.d).join() === 'sat,sun', `${w}: a ring only where the form and the page disagree on the day (Sat, Sun)`, R.chips.map((c) => [c.d, ringed(c)]))
  ok(R.chips.length && Math.abs(R.chips[0].top - R.leftChipTop) <= 1, `${w}: the chip row is level with the card's chip row`, [R.leftChipTop, R.chips[0] && R.chips[0].top])
  ok(R.rows.length === 6 && R.rows.every((x) => x.text != null), `${w}: one mirror row per day the page has (6), none for Sun`, R.rows.map((x) => [x.d, !!x.text]))
  ok(level(R), `${w}: every day row is level with the same day on the left (value and label within 1px)`, R.rows.map((x) => [x.d, x.lTop, x.rTop, x.lLabel, x.rLabel]))
  ok(R.rows.length && R.rows.every((x) => x.text != null && x.scriptHeight === ''), `${w}: no height is set in script on a mirror row`, R.rows.map((x) => x.scriptHeight))
  ok(R.typable === 0, `${w}: nothing to type in or tick inside the panel`, R.typable)
  ok(['tue', 'wed', 'fri'].every((d) => isOrange(rowsOf(R, d).open) && isOrange(rowsOf(R, d).close)), `${w}: a value that differs is an orange box (Tue, Wed, Fri)`, ['tue', 'wed', 'fri'].map((d) => [d, rowsOf(R, d).open, rowsOf(R, d).close]))
  ok(['mon', 'thu'].every((d) => rowsOf(R, d).open && !isOrange(rowsOf(R, d).open) && !isOrange(rowsOf(R, d).close) && rowsOf(R, d).open.bg === 'rgb(255, 255, 255)'), `${w}: a value that matches is a plain white box (Mon, Thu)`, ['mon', 'thu'].map((d) => [d, rowsOf(R, d).open]))
  ok(/Mon 10:00 PM to 6:00 AM Overnight, closes 6:00 AM the next day/.test(rowsOf(R, 'mon').text || ''), `${w}: Mon reads 10:00 PM, 6:00 AM with the green overnight line`, rowsOf(R, 'mon').text)
  ok(/9:00 PM to 5:00 AM Overnight, closes 5:00 AM the next day/.test(rowsOf(R, 'tue').text || ''), `${w}: Tue shows the form's 9:00 PM, 5:00 AM and its own overnight line`, rowsOf(R, 'tue').text)
  ok(/8:00 AM to 5:00 PM$/.test(rowsOf(R, 'wed').text || ''), `${w}: Wed (a day shift on the form) has no hint line`, rowsOf(R, 'wed').text)
  ok(rowsOf(R, 'sat').none && rowsOf(R, 'sat').none.text === 'No hours' && rowsOf(R, 'sat').none.color === 'rgb(185, 28, 28)', `${w}: Sat, which the form lacks, reads No hours in red`, rowsOf(R, 'sat').none)
  ok(/^Also on the form, not on this page: ?Sun 8:00 AM to 12:00 PM$/.test(R.extra), `${w}: the day only the form has is listed after the rows`, R.extra)
  ok(/Differs/.test(R.head) && R.buttons.includes("Use the form's hours"), `${w}: the top line says Differs with Use the form's hours`, [R.head, R.buttons])
  ok(!(await sideways(p)), `${w}: no sideways scroll`)
  if (w === 1440) {
    await p.locator('section[aria-label="When we can come on the form"]').first().scrollIntoViewIfNeeded().catch(() => {})
    await p.screenshot({ path: `${out}/A_differs_1440.png` })
    const calls0 = st.calls.length
    await p.getByRole('button', { name: "Use the form's hours" }).click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(800)
    const days = await Promise.all(['Tue', 'Sat', 'Sun', 'Fri'].map((d) => val(p, d)))
    const usedOk = days[0] === '21:00' && days[1] === null && days[2] === '08:00' && days[3] === '22:00'
    ok(usedOk, "1440: Use the form's hours puts the form's days on the draft", days)
    const R2 = await read(p)
    ok(/All the same/.test(R2.head) && !R2.buttons.includes("Use the form's hours"), '1440: then the top line reads All the same, no button', [R2.head, R2.buttons])
    ok(R2.rows.length === 6 && R2.rows.every((x) => x.open && !isOrange(x.open) && !isOrange(x.close) && !x.none) && R2.extra === '', '1440: then no orange box, no No hours, no extra list', R2.rows.map((x) => [x.d, x.text]))
    ok(level(R2), '1440: the rows are still level after the change (Sat gone, Sun added)', R2.rows.map((x) => [x.d, x.lTop, x.rTop]))
    const f = await footer(p)
    ok(!!f && /Used When we can come from the form of/.test(f.text) && f.undo, '1440: the sticky footer says what was used, with Undo', f && f.text.slice(0, 200))
    ok(usedOk && st.calls.length === calls0, '1440: using the form writes nothing to the database', st.calls.slice(calls0))
    await p.screenshot({ path: `${out}/A_used_1440.png` })
    await p.locator('div.sticky button', { hasText: /^Undo$/ }).first().click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(800)
    const back = await Promise.all(['Tue', 'Sat', 'Sun'].map((d) => val(p, d)))
    const R3 = await read(p)
    ok(usedOk && back[0] === '22:00' && back[1] === '22:00' && back[2] === null && /Differs/.test(R3.head), "1440: Undo puts the page's days back and the panel says Differs again", [back, R3.head])
  }
  ok(st.errors.length === 0, `${w}: no page errors`, st.errors)
  ok([...new Set(st.calls)].every((c) => ['get_page_builder', 'get_page_builder_forms', 'get_property_activity'].includes(c)), `${w}: no other call`, [...new Set(st.calls)])
  await ctx.close()
}

// B. The same hours on both sides
{
  const { ctx, p } = await open(1440, make(SAME, SAME))
  const R = await read(p)
  ok(/All the same/.test(R.head) && !R.buttons.length, 'same: the top line reads All the same, no button', [R.head, R.buttons])
  ok(R.rows.length === 6 && R.rows.every((x) => x.open && !isOrange(x.open) && !isOrange(x.close)) && !R.chips.some(ringed) && R.extra === '', 'same: six plain rows, no ring, no extra list', R.rows.map((x) => x.text))
  ok(level(R), 'same: rows level', R.rows.map((x) => [x.d, x.lTop, x.rTop]))
  await ctx.close()
}

// C. The page has no day yet: nothing to line up, every form day listed
{
  const { ctx, p } = await open(1440, make({}, FORM))
  const R = await read(p)
  ok(R.anyRow === 0, 'empty page: no mirror row (no left row to line up with)', R.anyRow)
  ok(R.chips.length === 7 && R.chips.filter(ringed).map((c) => c.d).join() === DAYS.filter((d) => FORM[d]).join(), 'empty page: every form day is filled and ringed', R.chips.map((c) => [c.d, ringed(c)]))
  const want = DAYS.filter((d) => FORM[d]).map((d) => `${d[0].toUpperCase() + d.slice(1)} ${T12[FORM[d].open]} to ${T12[FORM[d].close]}`)
  ok(R.extra.startsWith('Also on the form, not on this page:') && want.every((s) => R.extra.includes(s)), 'empty page: all six form days under Also on the form', R.extra)
  ok(/Empty here/.test(R.head) && R.buttons.includes("Use the form's hours"), "empty page: Empty here with Use the form's hours", [R.head, R.buttons])
  await p.screenshot({ path: `${out}/C_empty_1440.png` })
  await ctx.close()
}

// D. The form did not answer the hours
{
  const { ctx, p } = await open(1440, make(PAGE, null))
  const R = await read(p)
  ok(R.present && /Not on the form/.test(R.head) && R.chips.length === 0 && R.anyRow === 0 && !R.buttons.length, 'no answer: the panel says Not on the form, no chips, no rows, no button', [R.head, R.chips.length, R.anyRow, R.buttons])
  await ctx.close()
}

// E. Below 1280px nothing new mounts; the phone card is unchanged
for (const w of [1279, 390]) {
  const { ctx, p, st } = await open(w, make(PAGE, FORM))
  const R = await read(p)
  ok(!R.present && R.anyMirror === 0 && R.anyRow === 0, `${w}: no panel, no mirror chip, no mirror row`, [R.present, R.anyMirror, R.anyRow])
  ok(R.rows.length === 6, `${w}: the card still shows the page's six days`, R.rows.map((x) => x.d))
  if (w < 768) {
    const m = await p.evaluate(() => [...document.querySelectorAll('input[type="time"]')].map((i) => { const b = i.getBoundingClientRect(); return [Math.round(b.height), getComputedStyle(i).fontSize] }))
    ok(m.length === 12 && m.every(([h, f]) => h >= 44 && f === '16px'), `${w}: the time fields stay 44px or taller with 16px text`, m)
    ok(R.leftChipH >= 44, `${w}: the day chips stay 44px or taller`, R.leftChipH)
  }
  ok(!(await sideways(p)), `${w}: no sideways scroll`)
  ok(st.errors.length === 0, `${w}: no page errors`, st.errors)
  await ctx.close()
}

await browser.close()
if (process.env.CHUNK_SUB) console.log('CHUNK_SUB edits applied:', [...new Set(subHits)].length, 'of', process.env.CHUNK_SUB.split('@@@').length)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
