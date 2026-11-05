// LIVE Picture Planner /forms and /forms/<id> (office training film, screens 2 and 3, Fred's "Fix it", 2026-11-05): a waiting form says who
// is going, and the list re-reads itself. Sign-in faked, every backend call answered here, demo rows only: nothing is written anywhere.
//   node scripts/page-builder/tests/forms_going_reread.mjs <outdir>                  the live chunks: every check must PASS
//   node scripts/page-builder/tests/forms_going_reread.mjs <outdir> noseq            drops the newest-reply guard: exactly "a late older reply" must FAIL
// Before the publish (2026-11-05) the same checks ran on the old chunks: exactly the 26 line and re-read checks failed.
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const APP = (app, name, level, parent = null) => ({ app, name, parent, mode: 'on', level })
const FO = { employee_id: 990003, group: 'field', apps: [APP('picture_planner', 'Picture Planner', 'none'), APP('pp_forms', 'See their assigned forms', 'yes', 'picture_planner')] }
const STAFF = { employee_id: 990004, group: 'office', full_name: 'Dana', apps: [APP('picture_planner', 'Picture Planner', 'edit'), APP('pp_forms', 'See their assigned forms', 'yes', 'picture_planner')] }
const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = 4102444800, MAIL = 'dana@example.com'
const user = { id: '00000000-0000-4000-8000-000000000042', aud: 'authenticated', role: 'authenticated', email: MAIL, app_metadata: {}, user_metadata: {}, created_at: '2026-01-01T00:00:00Z' }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: MAIL, role: 'authenticated', aud: 'authenticated', exp, aal: 'aal1' })}.${Buffer.alloc(32, 7).toString('base64url')}`, refresh_token: 'canned', token_type: 'bearer', expires_in: 3600, expires_at: exp, user }

const row = (id, code, name, o = {}) => ({ intake_id: id, client_code: code, client_name: name, address: `${id} Demo Street`, city: 'Miami', state: 'awaiting', status: null, client_id: 1, collector: null, expires_at: '2026-12-04T14:00:00Z', has_gt_pin: false, has_truck_pin: false, property_id: id, requested_at: `2026-11-0${(id % 4) + 1}T14:00:00Z`, requested_by: 'Dana', submitted_at: null, answered_count: 0, requested_count: 23, applicable_count: 23, property_deleted: false, photo_count: 0, going: null, ...o })
const LIST = () => [
  row(901, '901-MSB', 'Main Street Burger', { going: 'Going: Michael Escobar, task on Nov 4' }),
  row(902, '902-PLZ', 'Plaza Pizza', { going: 'No task. It was deleted.' }),
  row(905, '905-OAK', 'Oak Street Diner', { going: 'No task is linked to this form.' }),
  row(906, '906-TWO', 'Two People Cafe', { going: 'Going: Grecia, Michael Escobar, task on Nov 9' }),
  ...Array.from({ length: 28 }, (_, i) => row(1000 + i, `${100 + i}-XX`, `Demo ${i}`, { state: 'submitted', status: 'Complete', collector: 'Michael Escobar', submitted_at: `2026-10-${String((i % 27) + 1).padStart(2, '0')}T17:20:00Z`, answered_count: 23, photo_count: 5 })),
]

// the guard control: the live list chunk with its newest-reply check taken out (names are per build)
function patchIndex(t) {
  const m = t.match(/if\(\w+!==\w+\.current\)return;(?=if\(\w+\)\{\w+\|\|\w+\(\w+\.message\);return\})/)
  if (!m) throw new Error('the newest-reply guard was not found in the list chunk')
  return t.replace(m[0], '')
}

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './forms_shots'; fs.mkdirSync(out, { recursive: true })
const want = process.argv[3] || 'today'
let pass = 0, fail = 0, lines = []
const ok = (c, name, v) => { c ? pass++ : fail++; lines.push(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 200)}`) }

async function open(w, who, path, mode, opts = {}) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 812 : 900 }, deviceScaleFactor: 1, isMobile: phone, hasTouch: phone, colorScheme: 'light', locale: 'en-US', timezoneId: 'America/New_York' })
  await ctx.route(/~flock|~api\/analytics|lovable\.dev\/|gpteng/, (r) => r.abort())
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript(([u, th]) => {
    try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })); if (th) localStorage.setItem('unclogme.theme', th) } catch {}
    window.__iv = []; const si = window.setInterval, ci = window.clearInterval
    window.setInterval = (f, ms, ...a) => { const id = si(f, ms, ...a); window.__iv.push({ id, ms, f }); return id }
    window.clearInterval = (id) => { window.__iv = window.__iv.filter((x) => x.id !== id); ci(id) }
  }, [user, opts.theme])
  if (mode !== 'today') {
    await ctx.route('**/assets/_staff.forms.index-*.js', async (r) => { const res = await r.fetch(); r.fulfill({ response: res, body: patchIndex(await res.text()) }) })
  }
  const p = await ctx.newPage()
  const st = { reads: 0, calls: [], rows: LIST(), delay: 0, errors: [], other: [] }
  p.on('pageerror', (e) => st.errors.push(String(e)))
  await p.route(SB + '/**', async (x) => {
    const r = x.request(), u = new URL(r.url()), n = u.pathname.split('/').pop(), j = (s, b) => x.fulfill({ status: s, contentType: 'application/json', body: JSON.stringify(b) })
    if (u.pathname.startsWith('/storage/v1/object/public/app-assets/')) return x.continue()   // the Dark stylesheet
    if (u.pathname.startsWith('/auth/v1/')) return j(200, user)
    if (!u.pathname.startsWith('/rest/v1/')) { st.other.push(u.pathname); return x.abort() }
    st.calls.push(n)
    let b = {}; try { b = JSON.parse(r.postData() || '{}') } catch {}
    if (n === 'get_my_access') return j(200, who === 'fo' ? FO : STAFF)
    if (n === 'list_intake_forms') {
      st.reads++
      if (st.reads === 1 && opts.firstStatus) {   // the first load answers late, and may fail
        await new Promise((res) => setTimeout(res, 2000))
        return opts.firstStatus === 200 ? j(200, st.rows) : j(opts.firstStatus, { message: 'first load failed', code: 'X', details: null, hint: null })
      }
      const snap = JSON.parse(JSON.stringify(st.rows)), d = st.delay; st.delay = 0
      if (d) await new Promise((res) => setTimeout(res, d))
      return j(200, snap)
    }
    if (n === 'get_intake_link') return j(200, { ok: true, intake_id: Number(b.p_intake_id), url: H + '/intake.html#code=FAKE-test', expires_at: '2026-12-04T14:00:00Z' })
    if (n === 'cancel_intake') { st.rows = st.rows.filter((q) => Number(q.intake_id) !== Number(b.p_intake_id)); return j(200, { intake_id: Number(b.p_intake_id) }) }
    if (n === 'get_intake') return j(200, { intake_id: 901, state: 'awaiting', status: null, missing: null, property: { id: 1, address: '901 Demo Street', city: 'Miami', deleted: false, client_id: 1, client_code: '901-MSB', client_name: 'Main Street Burger' }, requested_by: 'Dana', requested_at: '2026-11-04T14:00:00Z', expires_at: '2026-12-04T14:00:00Z', collector: null, submitted_at: null, requested_count: 23, applicable_count: null, sections: [], unlisted_answers: [], unlisted_photos: [], accepted: [], size_lookups: null, forms_only: who === 'fo', going: who === 'fo' ? undefined : 'Going: Michael Escobar, task on Nov 4' })
    return j(403, { code: '42501', message: 'not stubbed ' + n, details: 'blocker=no_access', hint: null })
  })
  await p.goto(H + path, { waitUntil: 'domcontentloaded' })
  if (opts.firstStatus) {   // the tab gets focus while the first load is still out
    for (let i = 0; i < 100 && st.reads === 0; i++) await p.waitForTimeout(50)
    await p.waitForTimeout(150)
    await p.evaluate(() => window.dispatchEvent(new Event('focus')))
    await p.waitForTimeout(5000)
    return { p, ctx, st }
  }
  await p.waitForTimeout(2800)
  return { p, ctx, st }
}
const tick = (p) => p.evaluate(() => { const x = window.__iv.find((y) => y.ms === 60000); if (x) x.f(); return !!x })
const cardCount = (p) => p.evaluate(() => document.querySelectorAll('main a[href^="/forms/"]').length)
const settle = (p, ms = 500) => p.waitForTimeout(ms)
const menu = (p, code) => p.locator(`button[aria-label^="More actions for ${code}"]`).click()

for (const mode of [want]) {
  for (const w of mode === 'noseq' ? [1440] : [1440, 375]) {
    const tag = `${mode} ${w}`
    const { p, ctx, st } = await open(w, 'staff', '/forms', mode)
    // A: the line on the cards
    const going = await p.evaluate(() => [...document.querySelectorAll('main a[href^="/forms/"] div')].filter((e) => e.children.length === 0 && /^(Going:|No task)/.test(e.textContent.trim())).map((e) => ({ t: e.textContent.trim(), c: getComputedStyle(e).color, w: getComputedStyle(e).fontWeight, h: Math.round(e.getBoundingClientRect().height) })))
    ok(going.length === 4, `${tag} the line shows on the 4 waiting cards`, going.length)
    const amber = await p.evaluate(() => { const x = document.createElement('span'); x.className = 'text-amber-800'; document.body.append(x); const c = getComputedStyle(x).color; x.remove(); return c })
    ok(going.some((g) => g.t === 'No task. It was deleted.' && g.c === amber), `${tag} deleted reads amber`, { amber, going })
    ok(going.some((g) => g.t === 'No task is linked to this form.' && g.c === amber), `${tag} no task linked reads amber`)
    ok(going.some((g) => g.t.startsWith('Going: Michael') && g.c === 'rgb(24, 24, 27)' && g.w === '700'), `${tag} Going reads bold ink`)
    await p.screenshot({ path: `${out}/forms_cards_${mode}_${w}.png`, clip: { x: 0, y: 0, width: w, height: 560 } })
    // B: the re-read
    ok(st.reads === 1, `${tag} one read at mount`, st.reads)
    const iv = await p.evaluate(() => window.__iv.map((x) => x.ms))
    ok(iv.includes(60000), `${tag} a 60 s timer exists`, iv)
    const before = st.reads
    await p.evaluate(() => window.dispatchEvent(new Event('focus'))); await settle(p)
    ok(st.reads === before + 1, `${tag} focus re-reads`, st.reads - before)
    await tick(p); await settle(p)
    ok(st.reads === before + 2, `${tag} the timer re-reads`, st.reads - before)
    await p.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, get: () => true }) })
    const b2 = st.reads; await tick(p); await settle(p)
    ok(st.reads === b2, `${tag} a hidden tab does not read`, st.reads - b2)
    await p.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, get: () => false }); document.dispatchEvent(new Event('visibilitychange')) }); await settle(p)
    ok(st.reads === b2 + 1, `${tag} coming back to the tab reads`, st.reads - b2)
    // the card flips by itself, with no reload and no Loading flash
    const loadingSeen = await p.evaluate(() => { window.__sawLoading = false; const o = new MutationObserver(() => { if (document.body.textContent.includes('Loading intake forms')) window.__sawLoading = true }); o.observe(document.body, { childList: true, subtree: true }); return true })
    st.rows = st.rows.map((r) => r.intake_id === 901 ? { ...r, state: 'submitted', status: 'Incomplete', collector: 'Michael Escobar', submitted_at: '2026-11-04T17:20:00Z', going: null, answered_count: 22, photo_count: 5 } : r)
    await tick(p); await settle(p)
    const flipped = await p.evaluate(() => document.querySelector('main a[href="/forms/901"]')?.textContent || '')
    ok(/Collected by Michael Escobar/.test(flipped) && !/Going:/.test(flipped), `${tag} a form that came back flips by itself`, flipped.slice(0, 80))
    ok((await p.evaluate(() => window.__sawLoading)) === false && loadingSeen, `${tag} no Loading flash`)
    // the search, the filter and the scroll stay
    const search = p.locator('input[placeholder^="Search by client code"]')
    await p.getByRole('button', { name: 'Submitted', exact: true }).click()
    await search.click(); await search.fill('Demo')
    await settle(p, 200)
    const nFiltered = await cardCount(p)
    await p.evaluate(() => window.scrollTo(0, 500)); await settle(p, 200)
    const y0 = await p.evaluate(() => window.scrollY)
    await tick(p); await settle(p)
    const after = await p.evaluate(() => ({ y: window.scrollY, q: document.querySelector('input[placeholder^="Search by client code"]').value, focus: document.activeElement?.tagName, btn: [...document.querySelectorAll('main button')].find((b) => b.textContent === 'Submitted')?.className.includes('bg-primary') }))
    ok(after.q === 'Demo' && after.focus === 'INPUT', `${tag} the search text and the focus stay`, after)
    ok(after.btn === true && (await cardCount(p)) === nFiltered, `${tag} the filter stays`, nFiltered)
    ok(y0 > 0 && after.y === y0, `${tag} the scroll stays`, { y0, y: after.y })
    await p.evaluate(() => window.scrollTo(0, 0))
    await p.getByRole('button', { name: 'All', exact: true }).click(); await search.fill(''); await settle(p, 200)
    // no read while a menu or a dialog is open; the link is only fetched on the press
    await menu(p, '902-PLZ'); await settle(p, 300)
    const b3 = st.reads; await tick(p); await settle(p)
    ok(st.reads === b3, `${tag} no read while the three-dot menu is open`, st.reads - b3)
    await p.getByRole('menuitem', { name: 'Share form' }).click(); await settle(p, 500)
    const linkCalls = st.calls.filter((c) => c === 'get_intake_link').length
    ok(linkCalls === 1, `${tag} the link was fetched once, on the press`, linkCalls)
    const b4 = st.reads; await tick(p); await settle(p)
    ok(st.reads === b4, `${tag} no read while Share form is open`, st.reads - b4)
    await p.getByRole('button', { name: 'Close', exact: true }).first().click(); await settle(p, 500)
    await tick(p); await settle(p)
    ok(st.reads === b4 + 1, `${tag} reads again once Share form closed`, st.reads - b4)
    await menu(p, '902-PLZ'); await settle(p, 300)
    await p.getByRole('menuitem', { name: 'Cancel form' }).click(); await settle(p, 400)
    const b5 = st.reads; await tick(p); await settle(p)
    ok(st.reads === b5, `${tag} no read while Cancel form is open`, st.reads - b5)
    await p.getByRole('button', { name: 'Keep the form' }).click(); await settle(p, 500)
    // an older reply never puts a cancelled card back
    st.delay = 1800
    await tick(p); await settle(p, 200)   // this read holds the old rows and answers late
    await menu(p, '902-PLZ'); await settle(p, 300)
    await p.getByRole('menuitem', { name: 'Cancel form' }).click(); await settle(p, 300)
    await p.getByRole('button', { name: 'Cancel the form' }).click(); await settle(p, 400)
    await p.waitForTimeout(2200)
    const back = await p.evaluate(() => !!document.querySelector('main a[href="/forms/902"]'))
    ok(!back, `${tag} a late older reply does not bring a cancelled card back`, back)
    // nothing but the expected calls
    const names = [...new Set(st.calls)].sort()
    ok(names.every((n) => ['cancel_intake', 'get_intake_link', 'get_my_access', 'list_intake_forms'].includes(n)), `${tag} only the expected calls`, names)
    ok(st.errors.length === 0, `${tag} no page errors`, st.errors.slice(0, 2))
    // leaving the page stops it
    await p.locator('main a[href="/forms/905"]').click(); await settle(p, 1500)
    const b6 = st.reads
    await p.evaluate(() => window.dispatchEvent(new Event('focus'))); await settle(p)
    const gone = await p.evaluate(() => !window.__iv.some((x) => x.ms === 60000))
    ok(st.reads === b6 && gone, `${tag} leaving Forms stops the timer and the listeners`, { reads: st.reads - b6, gone })
    // A on the form page: under the sentence, above the Collector link
    const page = await p.evaluate(() => { const t = document.querySelector('main')?.textContent || ''; return { going: t.indexOf('Going: Michael'), sentence: t.indexOf('Requested by'), link: t.indexOf('Collector link') } })
    ok(page.going > page.sentence && page.going < page.link && page.sentence >= 0, `${tag} the form page shows the line between the sentence and the Collector link`, page)
    await p.screenshot({ path: `${out}/forms_page_${mode}_${w}.png`, clip: { x: 0, y: 0, width: w, height: 420 } })
    await ctx.close()
    // Forms-only: no line, even if the server were wrong
    const fo = await open(w, 'fo', '/forms', mode)
    fo.st.rows = [row(901, '901-MSB', 'Main Street Burger', { going: 'Going: Michael Escobar, task on Nov 4' })]
    await fo.p.reload({ waitUntil: 'domcontentloaded' }); await fo.p.waitForTimeout(2800)
    const foText = await fo.p.evaluate(() => document.querySelector('main')?.textContent || '')
    ok(!/Going:/.test(foText) && !/Requested by/.test(foText) && /Link expires/.test(foText), `${tag} a Forms-only card shows no line and no requester`, foText.slice(0, 120))
    await fo.ctx.close()
  }
  // Dark: an inline colour is not recoloured there (measured before the build: contrast 1.01, the line invisible)
  const readLines = (p) => p.evaluate(() => {
    const px = (c) => { const k = document.createElement('canvas').getContext('2d', { willReadFrequently: true }); k.fillStyle = '#000'; k.fillStyle = c; k.fillRect(0, 0, 1, 1); return [...k.getImageData(0, 0, 1, 1).data].slice(0, 3) }
    const bgOf = (e) => { let n = e; while (n) { const c = getComputedStyle(n).backgroundColor; if (c && c !== 'rgba(0, 0, 0, 0)' && c !== 'transparent') return c; n = n.parentElement } return 'rgb(255,255,255)' }
    const lum = ([r, g, b]) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4 }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b) }
    const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return Math.round(((x + 0.05) / (y + 0.05)) * 100) / 100 }
    return [...document.querySelectorAll('main div, main p')].filter((e) => !e.children.length && /^(Going:|No task)/.test(e.textContent.trim())).map((e) => ({ t: e.textContent.trim().slice(0, 30), r: ratio(px(getComputedStyle(e).color), px(bgOf(e))) }))
  })
  if (mode !== 'noseq') for (const w of [1440, 375]) {
    const { p, ctx } = await open(w, 'staff', '/forms', mode, { theme: 'dark' })
    await p.waitForTimeout(1200)
    const list = await readLines(p)
    ok(list.length === 4 && list.every((x) => x.r >= 4.5), `${mode} ${w} Dark: every line on the list is readable`, list)
    await p.screenshot({ path: `${out}/forms_cards_dark_${mode}_${w}.png`, clip: { x: 0, y: 0, width: w, height: 560 } })
    await p.locator('main a[href="/forms/901"]').click(); await settle(p, 1500)
    const page = await readLines(p)
    ok(page.length === 1 && page[0].r >= 4.5, `${mode} ${w} Dark: the line on the form page is readable`, page)
    await p.screenshot({ path: `${out}/forms_page_dark_${mode}_${w}.png`, clip: { x: 0, y: 0, width: w, height: 420 } })
    await ctx.close()
  }
  // a focus while the first load is out must not strand the page on "Loading" with no Retry, and must not throw away a good reply
  if (mode !== 'noseq') {
    const main = (p) => p.evaluate(() => { const m = document.querySelector('main')?.textContent || ''; return { loading: m.includes('Loading intake forms'), error: m.includes('Could not load the intake forms'), retry: [...document.querySelectorAll('main button')].some((b) => b.textContent === 'Retry'), cards: document.querySelectorAll('main a[href^="/forms/"]').length } })
    const a = await open(1440, 'staff', '/forms', mode, { firstStatus: 500 })
    const ra = await main(a.p)
    ok(!ra.loading && ra.error && ra.retry && a.st.reads === 1, `${mode} first load fails with a focus during it: the error and Retry, no second read`, { ...ra, reads: a.st.reads })
    await a.ctx.close()
    const b = await open(1440, 'staff', '/forms', mode, { firstStatus: 200 })
    const rb = await main(b.p)
    ok(!rb.loading && rb.cards > 0 && b.st.reads === 1, `${mode} first load good with a focus during it: the cards, no second read`, { ...rb, reads: b.st.reads })
    await b.ctx.close()
  }
  console.log(`=== ${mode}: ${lines.filter((l) => l.startsWith('PASS')).length} pass, ${lines.filter((l) => l.startsWith('FAIL')).length} fail`)
  for (const l of lines.filter((x) => x.startsWith('FAIL'))) console.log(l)
  lines = []
}
await browser.close()
process.exit(lines.length || fail ? 1 : 0)
