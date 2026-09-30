// LIVE Picture Planner form page /forms/<id>: the "Collector link" block at the top of a WAITING form (2026-09-30). Fred:
// "When opening a form https://planner.unclogme.app/forms/1041 like that one, we need to show there the link we shared to
// the collector, so we can open it again, and have it in case the collector needs it again. ... display it also at the view
// of the form on the top." He picked V1 (the link on open). Real replies read in SQL as Fred's claims (form 1038, cancelled
// before its collector submitted, on 112-YA property 1164, edited here to awaiting and to expired; form 715, submitted), then
// played back. Sign-in faked; EVERY call stubbed, get_intake_link included (a FAKE link, never a real code), so nothing is
// written and no reveal row is made. Never prints a reply.
// Spec: Building Apps/Picture Planner/docs/specs/2026-09-30-form-page-collector-link-design.md
//   node scripts/page-builder/tests/form_link.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_intake(1038) as c, client.get_intake(715) as s;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
const C0 = row && row.c, S0 = row && row.s
if (!C0 || C0.state !== 'cancelled' || C0.submitted_at || Number(C0.intake_id) !== 1038 || Number(C0.property && C0.property.id) !== 1164 || !(C0.sections || []).length || !S0 || S0.state !== 'submitted') {
  console.log('FAIL fixture: form 1038 must be cancelled before any submit, on 1164, and 715 submitted :: ' + ((r && r.message) || '')); process.exit(1)  // never the raw reply: 715 holds a lock box code
}
const clone = (x) => JSON.parse(JSON.stringify(x))
const ID = 1038
const AWAIT = clone(C0); AWAIT.state = 'awaiting'
const CANCELLED = clone(C0)
const EXPIRED = clone(C0); EXPIRED.state = 'expired'; EXPIRED.expires_at = '2026-09-01T12:00:00+00:00'
const REMOVED = clone(AWAIT); REMOVED.property.deleted = true
const RACED = clone(AWAIT); Object.assign(RACED, { state: 'submitted', status: 'Incomplete', submitted_at: new Date().toISOString(), collector: '[TEST] race collector', missing: [], applicable_count: 0 })
const URL1 = 'https://planner.unclogme.app/intake#code=FAKE0000FAKE0000'  // FAKE, 16 characters like a real code
const OTHER = 'https://planner.unclogme.app/intake#code=OTHEROTHEROTHER0'
const OK1 = { ok: true, intake_id: ID, url: URL1, expires_at: AWAIT.expires_at }
const MSG = {
  submitted: 'This form was already submitted, so its link cannot take answers any more. To collect again, schedule a new intake from the property in the Client App.',
  cancelled: 'This form was cancelled, so its link no longer opens.',
  expired: 'This link has expired. Schedule a new intake from the property in the Client App to get a new link.',
  property_removed: 'This property was removed, so its form should not be filled any more.',
}
const REFUSE = (b) => ({ s: 400, b: { code: '22023', message: MSG[b], details: `blocker=${b} in client.get_intake_link`, hint: null } })
const WARN = 'Anyone with this link can open the site survey and fill it in, with no login. The first person to submit it makes it final.'
const GENERIC = 'Could not get the link. Check your connection and try again. If it keeps failing, sign in again.'
const COPYFAIL = 'Could not copy. Press and hold the link, or select it, and copy it.'
const I1 = URL1.indexOf('/intake') + 1, I2 = URL1.indexOf('#')  // the only two places the link may break

const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './form_link_shots'; fs.mkdirSync(out, { recursive: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 400)}`) }
const subHits = []
// sc: { intake: [{ b, d }], link: [{ s, b, d, abort }] }, one entry per call in order, the last one repeats
async function open(w, id, sc) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => {
    try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {}
    window.__clip = []; window.__opens = []; window.__clipFail = false; window.__flash = 0
    Object.defineProperty(Navigator.prototype, 'clipboard', { configurable: true, get: () => ({ writeText: (t) => { window.__clip.push(String(t)); return window.__clipFail ? Promise.reject(new Error('denied')) : Promise.resolve() } }) })
    // records the call and whether it ran inside the click itself (window.event is the click only synchronously)
    window.open = function (url, target, features) { window.__opens.push({ u: String(url), t: target ?? null, f: features ?? null, ev: window.event ? window.event.type : null }); return null }
    let seen = false  // a "Loading the form" after the header was drawn = a reload that was not quiet
    new MutationObserver(() => { if (!seen) seen = !!document.querySelector('main header h1'); else if (document.body && document.body.textContent.includes('Loading the form')) window.__flash++ }).observe(document, { subtree: true, childList: true, characterData: true })
  }, user)
  const p = await ctx.newPage()
  const st = { calls: [], bodies: [], n: {}, errors: [], logs: [], users: 0 }
  p.on('pageerror', (e) => st.errors.push(String(e)))
  p.on('console', (m) => st.logs.push(m.text()))
  await p.route(SB + '/auth/v1/**', (x) => { if (new URL(x.request().url()).pathname.endsWith('/user')) st.users++; return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }) })
  await p.route(SB + '/rest/v1/**', async (x) => {
    const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n)
    let b = {}; try { b = JSON.parse(x.request().postData() || '{}') } catch {}
    if (n === 'get_intake_link') st.bodies.push(b)
    const k = (st.n[n] = (st.n[n] || 0) + 1) - 1
    const list = n === 'get_intake' ? sc.intake : n === 'get_intake_link' ? sc.link : null
    const rep = list && list[Math.min(k, list.length - 1)]
    if (!rep) return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' })
    if (rep.d) await new Promise((res) => setTimeout(res, rep.d))
    if (rep.abort) return x.abort().catch(() => {})
    return x.fulfill({ status: rep.s || 200, contentType: 'application/json', body: JSON.stringify(rep.b) }).catch(() => {})
  })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route(SB + '/functions/v1/**', (x) => x.abort())
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + '/forms/' + id)
  await p.waitForSelector('main header h1', { timeout: 30000 }).catch(() => {})
  return { ctx, p, st }
}
const count = (st, n) => st.calls.filter((c) => c === n).length
// the header, the block, the link box and its lines (measured per character), the block's buttons
const read = (p) => p.evaluate(() => {
  const t = (s) => (s == null ? null : s.replace(/\s+/g, ' ').trim())
  const hd = document.querySelector('main header')
  const status = hd && [...hd.querySelectorAll('p')].find((x) => /^(Waiting for the collector\.|The collector never|Cancelled|This is what)/.test(t(x.textContent)))
  const blk = document.querySelector('[data-collector-link]')
  const box = blk && blk.querySelector('[data-collector-link-url]')
  const lines = (node) => { const res = []; let y = null, cur = ''; const tw = document.createTreeWalker(node, NodeFilter.SHOW_TEXT); for (let n = tw.nextNode(); n; n = tw.nextNode()) for (let i = 0; i < n.length; i++) { const rg = document.createRange(); rg.setStart(n, i); rg.setEnd(n, i + 1); const top = Math.round(rg.getBoundingClientRect().top); if (y !== null && top > y + 2) { res.push(cur); cur = '' } y = top; cur += n.data[i] } res.push(cur); return res }
  const cs = box && getComputedStyle(box)
  return {
    status: status ? t(status.textContent) : null,
    block: blk ? { text: t(blk.textContent), inHeader: !!(hd && hd.contains(blk)), afterStatus: !!(status && (status.compareDocumentPosition(blk) & Node.DOCUMENT_POSITION_FOLLOWING)), label: t((blk.firstElementChild || {}).textContent), alerts: [...blk.querySelectorAll('[role="alert"]')].map((a) => t(a.textContent)), ps: [...blk.querySelectorAll('p')].map((a) => t(a.textContent)) } : null,
    anyLabel: /Collector link/.test(document.body.textContent),
    box: box ? { text: box.textContent, h: Math.round(box.getBoundingClientRect().height), font: cs.fontFamily, us: cs.userSelect || cs.webkitUserSelect, lines: lines(box) } : null,
    btns: blk ? [...blk.querySelectorAll('button')].map((b) => { const r = b.getBoundingClientRect(), s = getComputedStyle(b); return { t: t(b.textContent), dis: b.disabled, w: Math.round(r.width), h: Math.round(r.height), bg: s.backgroundColor, fs: s.fontSize, fw: s.fontWeight } }) : [],
    sideways: document.documentElement.scrollWidth > innerWidth,
  }
})
const btn = (p, re) => p.locator('[data-collector-link] button', { hasText: re }).first()
const waitAlert = (p, ms) => p.waitForFunction(() => { const b = document.querySelector('[data-collector-link]'); return !!(b && b.querySelector('[role="alert"]')) }, null, { timeout: ms }).catch(() => {})
const waitUrl = (p, u, ms) => p.waitForFunction((x) => { const b = document.querySelector('[data-collector-link-url]'); return !!(b && b.textContent === x) }, u, { timeout: ms }).catch(() => {})
const leaks = async (p, st) => ({ ...(await p.evaluate((c) => { const all = []; for (const s of [localStorage, sessionStorage]) for (let i = 0; i < s.length; i++) all.push(String(s.getItem(s.key(i)))); return { storage: all.some((v) => v.includes(c)), href: location.href.includes(c) } }, 'FAKE0000FAKE0000')), console: st.logs.filter((l) => l.includes('FAKE0000')).length })

for (const w of [360, 390, 768, 1280]) {
  const phone = w < 768, HB = phone ? 44 : 36
  { // A. a waiting form: loading, the link, the buttons, Copy link (then a refused copy), Open form, one call
    const { ctx, p, st } = await open(w, ID, { intake: [{ b: AWAIT }], link: [{ b: OK1, d: 2500 }] })
    await p.waitForFunction(() => { const b = document.querySelector('[data-collector-link-url]'); return !!(b && /Getting the link/.test(b.textContent)) }, null, { timeout: 2000 }).catch(() => {})
    const L = await read(p)
    ok(!!L.block && L.block.label === 'Collector link' && !!L.box && /^Getting the link(\.\.\.|\u2026)$/.test(L.box.text.trim()), `${w}: while loading, "Collector link" and "Getting the link..." in the link box`, { label: L.block && L.block.label, box: L.box && L.box.text })
    ok(L.btns.map((b) => b.t).join() === 'Copy link,Open form' && L.btns.every((b) => b.dis), `${w}: while loading, Copy link and Open form are there and disabled`, L.btns.map((b) => [b.t, b.dis]))
    ok(!!L.block && L.block.ps.includes(WARN), `${w}: while loading, the warning sentence is there`, L.block && L.block.ps)
    await waitUrl(p, URL1, 6000); await p.waitForTimeout(300)
    const S = await read(p)
    ok(!!S.box && S.box.text === URL1, `${w}: the link box holds the link exactly as get_intake_link returned it`, S.box && S.box.text)
    ok(!!S.block && S.block.inHeader && S.block.afterStatus && S.block.label === 'Collector link' && /^Waiting for the collector\./.test(S.status || ''), `${w}: the block sits in the header card, under the status line, headed "Collector link"`, S.block && { inHeader: S.block.inHeader, afterStatus: S.block.afterStatus, label: S.block.label })
    const lb = S.box ? S.box.lines : []; const starts = []; let acc = 0; for (const l of lb) { starts.push(acc); acc += l.length }
    ok(lb.join('') === URL1 && starts.slice(1).every((i) => i === I1 || i === I2) && (phone ? lb.length <= 2 : lb.length === 1), `${w}: the link ${phone ? 'breaks only after ".app/" or before "#code="' : 'is on one line'}`, lb)
    ok(!!S.box && /mono|consolas|menlo|courier/i.test(S.box.font) && S.box.us === 'all', `${w}: the link is monospace text with select-all`, S.box && { font: S.box.font, us: S.box.us })
    ok(!!S.box && !!L.box && Math.abs(S.box.h - L.box.h) <= 1, `${w}: the link box keeps its loading height (nothing jumps)`, { loading: L.box && L.box.h, loaded: S.box && S.box.h })
    ok(S.btns.map((b) => b.t).join() === 'Copy link,Open form' && S.btns.every((b) => !b.dis && Math.abs(b.h - HB) <= 1 && b.fs === '14px' && b.fw === '600'), `${w}: Copy link and Open form, ${HB}px, 14px semibold`, S.btns)
    ok(S.btns.length === 2 && S.btns[0].bg === 'rgb(241, 71, 20)' && S.btns[1].bg === 'rgb(255, 255, 255)', `${w}: Copy link is orange, Open form is white (outlined)`, S.btns.map((b) => b.bg))
    // flex-1 on both, and Copy link carries a transparent 1.5px border like Open form's grey one, so the halves are equal
    // (without it flex-1 makes the outlined one wider: 130 and 132 at 360, 145 and 147 at 390, measured on a reference build)
    if (phone) ok(S.btns.length === 2 && Math.abs(S.btns[0].w - S.btns[1].w) <= 1, `${w}: on a phone the two buttons are equal halves`, S.btns.map((b) => b.w))
    ok(!!S.block && S.block.ps.includes(WARN) && !/expire/i.test(S.block.text), `${w}: the Share dialog's warning sentence, and no expiry repeated`, S.block && S.block.ps)
    ok(!S.sideways, `${w}: no sideways scroll`)
    await p.screenshot({ path: `${out}/waiting_${w}.png`, fullPage: false }).catch(() => {})
    if (!phone) {
      await p.locator('[data-collector-link-url]').click({ timeout: 2000 }).catch(() => {})
      const sel = await p.evaluate(() => { const s = getSelection().toString(); getSelection().removeAllRanges(); return s })
      ok(sel === URL1, `${w}: one click on the link selects all of it`, sel)
    }
    await btn(p, /^Copy link$/).click({ timeout: 2000 }).catch(() => {}); await p.waitForTimeout(300)
    const c1 = await p.evaluate(() => ({ clip: window.__clip.slice(), t: [...document.querySelectorAll('[data-collector-link] button')].map((b) => b.textContent.trim()) }))
    ok(c1.clip.length === 1 && c1.clip[0] === URL1 && c1.t[0] === 'Copied', `${w}: Copy link copies the link and reads Copied`, c1)
    await p.waitForTimeout(2300)
    const c2 = await p.evaluate(() => [...document.querySelectorAll('[data-collector-link] button')].map((b) => b.textContent.trim()))
    ok(c2[0] === 'Copy link', `${w}: 2 seconds later it reads Copy link again`, c2)
    await p.evaluate(() => { window.__clipFail = true })
    await btn(p, /^Copy link$/).click({ timeout: 2000 }).catch(() => {}); await p.waitForTimeout(400)
    const S3 = await read(p)
    ok(!!S3.block && S3.block.alerts.includes(COPYFAIL), `${w}: a refused copy says "${COPYFAIL}"`, S3.block && S3.block.alerts)
    await p.evaluate(() => { window.__clipFail = false })
    await btn(p, /^Copy link$/).click({ timeout: 2000 }).catch(() => {}); await p.waitForTimeout(400)
    const S4 = await read(p), n4 = await p.evaluate(() => window.__clip.length)
    ok(!!S4.block && S4.block.alerts.length === 0 && n4 === 3, `${w}: the next copy that works clears that sentence`, { alerts: S4.block && S4.block.alerts, copies: n4 })
    await btn(p, /^Open form$/).click({ timeout: 2000 }).catch(() => {}); await p.waitForTimeout(400)
    const o = await p.evaluate(() => window.__opens.slice())
    ok(o.length === 1 && o[0].u === URL1 && o[0].t === '_blank' && o[0].f === 'noopener' && o[0].ev === 'click', `${w}: Open form opens the loaded link in a new tab (noopener), inside the click`, o)
    // a tab refocus: auth-js re-reads the session on visibilitychange and tells the staff gate (SIGNED_IN), which re-checks;
    // the page must not remount or refetch, or every refocus would write another reveal row
    // (users0 < st.users proves the refocus reached the gate: its re-check asks /auth/v1/user)
    const users0 = st.users
    await p.evaluate(() => { document.dispatchEvent(new Event('visibilitychange', { bubbles: true })); window.dispatchEvent(new Event('focus')) }); await p.waitForTimeout(1500)
    ok(count(st, 'get_intake_link') === 1 && st.bodies.length === 1 && Number(st.bodies[0].p_intake_id) === ID && count(st, 'get_intake') === 1 && st.users > users0, `${w}: one get_intake_link call for this view (p_intake_id ${ID}), after one get_intake, Copy, Open and a tab refocus included`, { link: count(st, 'get_intake_link'), intake: count(st, 'get_intake'), bodies: st.bodies, gateRechecks: st.users - users0 })
    const lk = await leaks(p, st)
    ok(!lk.storage && !lk.href && lk.console === 0, `${w}: the link is in no storage, not in the URL, not in the console`, lk)
    ok(st.errors.length === 0, `${w}: no page errors`, st.errors)
    await ctx.close()
  }
  { // B. a waiting form whose property was removed: the database's sentence, no buttons, no reload
    const { ctx, p, st } = await open(w, ID, { intake: [{ b: REMOVED }], link: [REFUSE('property_removed')] })
    await waitAlert(p, 6000); await p.waitForTimeout(1500)
    const S = await read(p)
    ok(!!S.block && S.block.label === 'Collector link' && S.block.alerts.join('|') === MSG.property_removed, `${w}: removed property: the database's sentence under "Collector link"`, S.block && S.block.alerts)
    ok(!!S.block && S.btns.length === 0 && !S.box, `${w}: removed property: no link and no buttons`, { btns: S.btns, box: !!S.box })
    ok(count(st, 'get_intake_link') === 1 && count(st, 'get_intake') === 1, `${w}: removed property: one get_intake_link call and no reload`, { link: count(st, 'get_intake_link'), intake: count(st, 'get_intake') })
    await ctx.close()
  }
  { // C. the race: submitted in another tab after this page loaded; a quiet get_intake reload catches up
    const { ctx, p, st } = await open(w, ID, { intake: [{ b: AWAIT }, { b: RACED, d: 2500 }], link: [REFUSE('submitted')] })
    await waitAlert(p, 5000)
    const S1 = await read(p)
    ok(!!S1.block && S1.block.alerts.join('|') === MSG.submitted && S1.btns.length === 0, `${w}: race: the database's sentence and no buttons`, S1.block && { alerts: S1.block.alerts, btns: S1.btns.length })
    await p.waitForFunction(() => !document.querySelector('[data-collector-link]') && /This is what/.test((document.querySelector('main header') || {}).textContent || ''), null, { timeout: 8000 }).catch(() => {})
    const S2 = await read(p)
    ok(!S2.block && /^This is what \[TEST\] race collector collected on /.test(S2.status || '') && count(st, 'get_intake') === 2 && count(st, 'get_intake_link') === 1, `${w}: race: get_intake read again, the status line catches up and the block goes`, { status: S2.status, block: !!S2.block, intake: count(st, 'get_intake'), link: count(st, 'get_intake_link') })
    ok(await p.evaluate(() => window.__flash) === 0, `${w}: race: the reload is quiet (no "Loading the form")`)
    await ctx.close()
  }
  { // D. an error with no blocker=: the generic sentence and Try again, which asks once more
    const { ctx, p, st } = await open(w, ID, { intake: [{ b: AWAIT }], link: [{ s: 500, b: { message: 'boom' } }, { b: OK1 }] })
    await waitAlert(p, 6000); await p.waitForTimeout(300)
    const S = await read(p)
    ok(!!S.block && S.block.alerts.join('|') === GENERIC && S.btns.map((b) => b.t).join() === 'Try again' && Math.abs(S.btns[0].h - HB) <= 1 && !S.box, `${w}: error: "${GENERIC}" and one Try again button, ${HB}px`, S.block && { alerts: S.block.alerts, btns: S.btns })
    await btn(p, /^Try again$/).click({ timeout: 2000 }).catch(() => {})
    await waitUrl(p, URL1, 5000)
    const S2 = await read(p)
    ok(!!S2.box && S2.box.text === URL1 && count(st, 'get_intake_link') === 2, `${w}: Try again asks once more and shows the link`, { box: S2.box && S2.box.text, link: count(st, 'get_intake_link') })
    ok(!st.logs.some((l) => l.includes('boom')), `${w}: the console gets the code only, never the message`, st.logs.filter((l) => l.includes('boom')))
    await ctx.close()
  }
  { // E. a reply for another form is dropped: never shown, the generic sentence instead. (A reply that lands after the view
    // changed cannot render: the block is keyed by the form id, its ref is cleared on unmount and React drops a state update
    // after unmount; so this id check is the guard a test can see.)
    const { ctx, p, st } = await open(w, ID, { intake: [{ b: AWAIT }], link: [{ b: { ok: true, intake_id: ID - 1, url: OTHER, expires_at: AWAIT.expires_at } }] })
    await waitAlert(p, 6000); await p.waitForTimeout(500)
    const S = await read(p), html = await p.content()
    ok(!html.includes('OTHEROTHER') && !!S.block && S.block.alerts.join('|') === GENERIC && S.btns.map((b) => b.t).join() === 'Try again' && count(st, 'get_intake_link') === 1, `${w}: a reply for another form id is dropped (never shown; the generic sentence and Try again)`, { shown: html.includes('OTHEROTHER'), alerts: S.block && S.block.alerts, btns: S.btns.map((b) => b.t) })
    await ctx.close()
  }
  for (const [name, id, rep, re] of [['submitted', 715, S0, /^This is what /], ['cancelled', ID, CANCELLED, /^Cancelled before the collector submitted it\./], ['expired', ID, EXPIRED, /^The collector never submitted this form\./]]) {
    const { ctx, p, st } = await open(w, id, { intake: [{ b: rep }], link: [{ b: OK1 }] })
    await p.waitForTimeout(2500)
    const S = await read(p)
    ok(re.test(S.status || '') && !S.block && !S.anyLabel && count(st, 'get_intake_link') === 0, `${w}: ${name} form: no Collector link block and no get_intake_link call`, { status: S.status, block: !!S.block, label: S.anyLabel, link: count(st, 'get_intake_link') })
    await ctx.close()
  }
}
{ // F. at 1280: the race for a cancelled and an expired form, a refusal whose reload still says awaiting, a dropped connection
  for (const [b, rep, re] of [['cancelled', CANCELLED, /^Cancelled before the collector submitted it\./], ['expired', EXPIRED, /^The collector never submitted this form\./]]) {
    const { ctx, p, st } = await open(1280, ID, { intake: [{ b: AWAIT }, { b: rep, d: 2000 }], link: [REFUSE(b)] })
    await waitAlert(p, 5000)
    const S1 = await read(p)
    ok(!!S1.block && S1.block.alerts.join('|') === MSG[b] && S1.btns.length === 0, `1280: race (${b}): the database's sentence and no buttons`, S1.block && S1.block.alerts)
    await p.waitForFunction((src) => !document.querySelector('[data-collector-link]') && new RegExp(src).test(((document.querySelector('main header') || {}).textContent || '').replace(/\s+/g, ' ')), re.source.replace('^', ''), { timeout: 8000 }).catch(() => {})
    const S2 = await read(p)
    ok(!S2.block && re.test(S2.status || '') && count(st, 'get_intake') === 2 && count(st, 'get_intake_link') === 1, `1280: race (${b}): get_intake read again, the status line catches up and the block goes`, { status: S2.status, block: !!S2.block, intake: count(st, 'get_intake'), link: count(st, 'get_intake_link') })
    await ctx.close()
  }
  { const { ctx, p, st } = await open(1280, ID, { intake: [{ b: AWAIT }], link: [REFUSE('submitted')] })
    await waitAlert(p, 5000); await p.waitForTimeout(5000)
    const S = await read(p)
    ok(count(st, 'get_intake') === 2 && count(st, 'get_intake_link') === 1 && !!S.block && S.block.alerts.join('|') === MSG.submitted, '1280: a refusal whose reload still says awaiting: one reload, no second get_intake_link, the sentence stays', { intake: count(st, 'get_intake'), link: count(st, 'get_intake_link'), alerts: S.block && S.block.alerts })
    await ctx.close()
  }
  { const { ctx, p, st } = await open(1280, ID, { intake: [{ b: AWAIT }], link: [{ abort: true }] })
    await waitAlert(p, 6000)
    const S = await read(p)
    ok(!!S.block && S.block.alerts.join('|') === GENERIC && S.btns.map((b) => b.t).join() === 'Try again', '1280: a dropped connection: the generic sentence and Try again', S.block && { alerts: S.block.alerts, btns: S.btns.map((b) => b.t) })
    ok(st.errors.length === 0, '1280: a dropped connection: no page errors', st.errors)
    await ctx.close()
  }
}
await browser.close()
if (process.env.CHUNK_SUB) console.log(`CHUNK_SUB edits applied: ${new Set(subHits).size} of ${process.env.CHUNK_SUB.split('@@@').length}`)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
