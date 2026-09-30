// LIVE Page Builder /property/1164: the collector's comment on a form photo's card (Fred, 2026-09-29, with his picture of
// the old demo card: "the lock we had there before it's to put the notes from the collector"; he picked the card as his
// picture: the lock line holds the comment IN PLACE OF "From: <source>", and "From: <source>" moves into its tooltip).
// A form photo WITH a comment: the lock line, read only, wrapping, first line of the card, no From line; every other card
// keeps today's From line. The comment is looked up live (get_page_builder pool / referenced caption) and never reaches
// the draft, the Site file preview or the approval review (the staff note stays the only text drivers and clients read).
// Real replies read as Fred's claims, then edited: every intake caption cleared, then two FIXTURE comments on two form
// photos of the live version (never in Prod). Sign-in faked, every call stubbed, every photo signed to a 1x1 fixture image
// (so the preview and the review draw the photos and their notes), Maps aborted, nothing written.
// Spec: Building Apps/Picture Planner/docs/specs/2026-09-29-pin-warning-map-fit-design.md, part C
//   node scripts/page-builder/tests/photo_comment_card.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (a control: named checks must FAIL)
//   LEAK=1  the control of F8, F9 and F10: the short fixture comment is ALSO written into that photo's STAFF note in the
//           live version (so in the waiting one too), which the draft, the preview and the review do show: exactly those
//           five checks must then FAIL (it proves the three "never shows it" checks can see a leak at all)
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
if (!row || !row.pb || !row.pb.live || !Array.isArray(row.forms)) { console.log('FAIL fixture: 1164 needs a live version :: ' + ((r && r.message) || Object.keys(row || {}))); process.exit(1) }  // never the raw reply: it holds the link code
const clone = (x) => JSON.parse(JSON.stringify(x))
const D = clone({ pb: row.pb, forms: row.forms })
D.pb.property.source = clone(D.pb.live.source)  // no "Changed in the Client App's property data" notice
D.pb.pending = null
for (const x of [...(D.pb.pool || []), ...(D.pb.referenced || [])]) if (x.kind === 'intake') x.caption = null
// two form photos of the live version whose source label is unique on the page get a fixture comment
const byId = new Map([...(D.pb.pool || []), ...(D.pb.referenced || [])].map((x) => [String(x.photo_id), x]))
const src = (x) => `Site survey · ${x.label ?? x.question_key ?? 'photo'}`
const onPage = (D.pb.live.content.photos || []).map((ph) => byId.get(String(ph.photo_id))).filter((x) => x && x.kind === 'intake' && x.owned !== false)
const unique = onPage.filter((x) => onPage.filter((y) => src(y) === src(x)).length === 1)
if (unique.length < 2) { console.log('FAIL fixture: the live version of 1164 needs two form photos with a unique source label', onPage.map(src)); process.exit(1) }
const SHORT = '[TEST] Alley access, enter here'
const LONG = '[TEST] The capacity plate is on the inside of the lid. It says 1000 gallons, but the numbers are faded, so check the manual in the office too.'
const C1 = unique[0], C2 = unique[1]
for (const x of [...(D.pb.pool || []), ...(D.pb.referenced || [])]) { if (String(x.photo_id) === String(C1.photo_id)) x.caption = SHORT; if (String(x.photo_id) === String(C2.photo_id)) x.caption = LONG }
const WANT = new Map([[src(C1), SHORT], [src(C2), LONG]])
if (process.env.LEAK) for (const ph of D.pb.live.content.photos) if (String(ph.photo_id) === String(C1.photo_id)) ph.note = SHORT
const N_CARDS = (D.pb.live.content.photos || []).length
const sameCls = (a, b) => (a || '').split(/\s+/).filter(Boolean).sort().join(' ') === b.split(/\s+/).sort().join(' ')
const TIP = (s) => `From: ${s}. Written by the collector on the form. Read only.`
const LABEL_BOX = 'flex items-center gap-1 rounded border border-border bg-muted/60 px-1.5 py-1 text-[11px] text-muted-foreground'
const LOCK_BOX = 'flex items-start gap-1 rounded border border-border bg-muted/60 px-1.5 py-1 text-sm text-muted-foreground md:text-[11px] cursor-default select-text'
// a waiting version (the live content again) for the approval review
const W = clone(D); W.pb.pending = { ...clone(W.pb.live), page_id: 999998, version: (W.pb.newest_version || 1) + 1, submitted_by_name: 'Someone', mine: false, approved_at: null, approved_by_name: null }
W.pb.newest_version = W.pb.pending.version; W.pb.can_approve = true; W.pb.approve_blocker = null

const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const PIXEL = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=', 'base64')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 400)}`) }
const out = process.argv[2] || './photo_comment_card_shots'; fs.mkdirSync(out, { recursive: true })
const subHits = [], calls = []
async function open(w, data) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { errors: [] }
  p.on('pageerror', (e) => { if (!/Google Maps/.test(String(e))) st.errors.push(String(e)) })
  const replies = { get_page_builder: data.pb, get_page_builder_forms: data.forms, get_property_activity: [], get_page_versions: [] }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); calls.push(n); if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) }); return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' }) })
  // every photo gets a signed url and a 1x1 image: the builder hands the preview and the review ONLY the photos whose url it
  // could sign (a photo without one is skipped), so with a refused signing F9 and F10 could never see a comment at all
  await p.route(SB + '/storage/v1/**', (x) => { const q = x.request()
    if (q.method() === 'POST' && q.url().includes('/object/sign/')) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ signedURL: '/object/sign/fixture/one-pixel.png?token=fixture' }) })
    if (q.method() === 'GET') return x.fulfill({ status: 200, contentType: 'image/png', body: PIXEL })
    return x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }) })
  await p.route(SB + '/functions/v1/**', (x) => x.abort())
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  await p.route('https://places.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + '/property/1164')
  await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent.trim() === 'Contacts'), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(3000)
  return { ctx, p, st }
}
// every photo card: its first line (the From line or the lock line), the staff note box and Remove
const cards = (p) => p.evaluate(() => [...document.querySelectorAll('[title="Drag to reorder or move to another category"]')].map((h) => {
  const card = h.parentElement, info = card.children[1], first = info && info.firstElementChild
  const t = (e) => (e ? e.textContent.replace(/\s+/g, ' ').trim() : null)
  const lock = card.querySelector('[data-collector-comment]')
  const sr = lock && lock.querySelector('.sr-only')
  const txt = lock && [...lock.querySelectorAll('span')].find((s) => s.querySelector('.sr-only'))
  const cs = txt && getComputedStyle(txt)
  // a From line: an element whose tooltip starts "From: " and equals its own text (the comment line's tooltip starts "From: " too, its text does not)
  const froms = [...card.querySelectorAll('[title^="From: "]')].filter((e) => t(e) === e.getAttribute('title')).length
  const ta = info && info.querySelector('textarea')
  return { firstIsLock: !!lock && first === lock, firstText: t(first), firstTitle: first && first.getAttribute('title'), firstCls: first && first.className,
    lock: lock ? { text: t(lock), shown: t(txt), title: lock.getAttribute('title'), cls: lock.className, sr: t(sr), hiddenIcon: !!lock.querySelector('[aria-hidden="true"]') && lock.querySelector('[aria-hidden="true"]').textContent.includes('\u{1F512}'),
      h: Math.round(lock.getBoundingClientRect().height), fs: getComputedStyle(lock).fontSize, ws: cs && cs.whiteSpace, clip: !!txt && (txt.scrollWidth > txt.clientWidth + 1 || (cs && cs.textOverflow === 'ellipsis')) } : null,
    froms, note: ta ? ta.placeholder : null, remove: !!info && [...info.querySelectorAll('button')].some((b) => b.textContent.trim() === 'Remove' && b.getClientRects().length > 0) }
}))
const dialogText = (p) => p.evaluate(() => { const d = [...document.querySelectorAll('[role="dialog"][aria-modal="true"]')].pop(); return d ? { title: (document.getElementById(d.getAttribute('aria-labelledby') || '') || {}).textContent || null, text: d.textContent.replace(/\s+/g, ' ') } : null })

for (const w of [390, 1440]) {
  const { ctx, p, st } = await open(w, D)
  const C = await cards(p)
  const L = C.filter((c) => c.lock)
  ok(C.length === N_CARDS && L.length === 2, `${w}: F1, exactly the two commented form photos carry the collector's comment line (one card per photo, ${N_CARDS})`, { cards: C.length, locks: L.length })
  ok(L.length === 2 && L.every((c) => c.firstIsLock), `${w}: F1, the comment line is the FIRST line of its card (in place of the From line)`, L.map((c) => c.firstText && c.firstText.slice(0, 30)))
  const got = new Map(L.map((c) => [c.lock.title, c]))
  ok(L.length === 2 && [...WANT.keys()].every((s) => got.has(TIP(s))), `${w}: F2, its tooltip is "From: <source>. Written by the collector on the form. Read only."`, L.map((c) => c.lock.title))
  ok(L.length === 2 && [...WANT].every(([s, want]) => { const c = got.get(TIP(s)); return c && c.lock.hiddenIcon && c.lock.sr === "Collector's comment, read only:" && c.lock.shown === `Collector's comment, read only: ${want}` }), `${w}: F2, a lock (aria-hidden), the screen reader words "Collector's comment, read only:" and the whole comment`, L.map((c) => ({ text: c.lock.text.slice(0, 60), sr: c.lock.sr, icon: c.lock.hiddenIcon })))
  ok(L.length === 2 && L.every((c) => c.froms === 0), `${w}: F3, a commented card has NO "From:" line`, L.map((c) => c.froms))
  const long = got.get(TIP(src(C2)))
  ok(!!long && !long.lock.clip && /pre-wrap|normal|pre-line|break-spaces/.test(long.lock.ws || '') && long.lock.h > 40, `${w}: F4, the long comment wraps in full (never cut, never "...")`, long && { h: long.lock.h, ws: long.lock.ws, clip: long.lock.clip })
  ok(L.length === 2 && L.every((c) => sameCls(c.lock.cls, LOCK_BOX) && c.lock.fs === (w < 768 ? '14px' : '11px')), `${w}: F7, the line as drawn: the From box's colours, 14px on a phone and 11px from 768px`, L.map((c) => ({ cls: c.lock.cls, fs: c.lock.fs })))
  const others = C.filter((c) => !c.lock && ![...WANT.keys()].some((s) => c.firstTitle === `From: ${s}`))
  ok(others.length === N_CARDS - 2 && others.every((c) => /^From: /.test(c.firstText || '') && c.firstTitle === c.firstText && sameCls(c.firstCls, LABEL_BOX) && c.froms === 1), `${w}: guard F5, every other card keeps today's From line (text, tooltip, box)`, others.map((c) => (c.firstText || '').slice(0, 30)))
  ok(C.every((c) => c.note === 'Notes for this photo (optional)' && c.remove), `${w}: guard F6, every card keeps its staff note box and Remove`, C.map((c) => [c.note, c.remove]))
  await p.locator('[data-collector-comment]').first().scrollIntoViewIfNeeded().catch(() => {}); await p.screenshot({ path: `${out}/card_${w}.png` }).catch(() => {})
  // F8: the comment never enters the draft (a staff note typed so the autosave writes one)
  const ta = p.locator('textarea[placeholder="Notes for this photo (optional)"]').first()
  await ta.scrollIntoViewIfNeeded().catch(() => {}); await ta.click().catch(() => {}); await p.keyboard.type(' x'); await p.waitForTimeout(2500)
  const dr = await p.evaluate(() => { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k.startsWith('pp-draft:')) return localStorage.getItem(k) } return null })
  ok(!!dr && !dr.includes('[TEST] Alley') && !dr.includes('capacity plate is on'), `${w}: F8, a draft was saved and it holds neither comment (the builder never copies it)`, { draft: !!dr })
  if (w < 768) ok(!(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth)), `${w}: no sideways scroll`)
  // F9: the Site file preview never shows it
  await p.evaluate(() => window.scrollTo(0, 0))
  await p.locator('button', { hasText: /^View site file$/ }).first().click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(1500)
  const pv = await dialogText(p)
  ok(!!pv && pv.title === 'Preview · Site file' && pv.text.length > 200 && !pv.text.includes('[TEST] Alley') && !pv.text.includes('capacity plate is on'), `${w}: F9, the "View site file" preview opens (guard) and shows neither comment`, pv && { title: pv.title, len: pv.text.length })
  await p.keyboard.press('Escape'); await p.waitForTimeout(500)
  ok(st.errors.length === 0, `${w}: no page errors`, st.errors)
  await ctx.close()
}
{ // F10: the approval review of a waiting version never shows it
  const { ctx, p } = await open(1440, W)
  const lockN = await p.locator('[data-collector-comment]').count()
  await p.locator('button', { hasText: /^Review version \d+$/ }).first().click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(1500)
  const rv = await dialogText(p)
  ok(!!rv && /Approve/.test(rv.text) && rv.text.length > 200 && !rv.text.includes('[TEST] Alley') && !rv.text.includes('capacity plate is on'), '1440: F10, the review of a waiting version opens (guard) and shows neither comment', rv && { title: rv.title, len: rv.text.length })
  ok(lockN === 2, '1440: F10b, the waiting version\'s own cards (behind the review) carry the two comment lines', lockN)
  await ctx.close()
}
ok(!calls.some((n) => !/^get_/.test(n)), 'nothing but reads was called', [...new Set(calls)])
await browser.close()
if (process.env.CHUNK_SUB) console.log('CHUNK_SUB edits applied:', [...new Set(subHits)].length, 'of', process.env.CHUNK_SUB.split('@@@').length)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
