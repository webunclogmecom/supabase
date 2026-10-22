// LIVE Page Builder /property/1208 (354-TBS, two waiting versions): Reject with a reason on the review screen and in
// Activity, Approve in Activity, the Rejected badge and rows, what version 1 filled in, the review box when nothing is live,
// and the counts bar (filled lock icon with its tooltip, centered row, the up arrow and its glow). Trello 1Mej1zDX, Fred's
// picks on the mockups of 2026-10-21. Real replies read as Fred (get_page_builder, forms, activity, versions); sign-in
// faked; EVERY write is stubbed and recorded (reject_property_page, approve_property_page): nothing is written.
//   node scripts/page-builder/tests/reject_counts.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@...' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const PID = 1208
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(${PID}) as pb, client.get_page_builder_forms(${PID}) as forms, client.get_property_activity(${PID}) as act, client.get_page_versions(${PID}) as versions;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
if (!row || !row.pb || !Array.isArray(row.versions)) { console.log('FAIL fixture :: ' + ((r && r.message) || '')); process.exit(1) }
const V = row.versions
if (V.length !== 2 || V.some((v) => v.status !== 'waiting') || !V.every((v) => v.can_approve && v.can_reject)) { console.log('FAIL fixture: 1208 should have two waiting versions Fred can decide :: ' + JSON.stringify(V.map((v) => [v.version, v.status, v.can_approve, v.can_reject]))); process.exit(1) }
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 300)}`) }
const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url'), exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './reject_counts_shots'; fs.mkdirSync(out, { recursive: true })
const clone = (x) => JSON.parse(JSON.stringify(x))
// what a version fills in, an independent copy of the rule (labels as page-diff.ts)
const LA = { key_tag: 'Key tag', gt_systems: 'Grease trap systems', gallons: 'Gallons', manholes: 'Manholes', cleanouts: 'Cleanouts', sample_ports: 'Sample ports', lift_stations: 'Lift stations', water_tanks: 'Water tanks', water_tank_capacity: 'Water tank capacity', gate: 'Gate', gate_code: 'Gate code', how_access: 'How to get in', lock_box_code: 'Lock box code', key_instruction: 'Key instructions', alarm: 'Alarm', alarm_instruction: 'Alarm instructions', equipment_where: 'Where the equipment is', access_point: 'Access point', obstacles: 'Obstacles' }
const factLines = (c) => Object.entries(c?.facts ?? {}).filter(([, v]) => v != null && v !== '').map(([k]) => LA[k] ?? k)

async function open(w, o = {}) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { calls: [], writes: [], errors: [] }
  p.on('pageerror', (e) => { if (!/Google Maps/.test(String(e))) st.errors.push(String(e)) })
  const replies = { get_page_builder: row.pb, get_page_builder_forms: row.forms, get_property_activity: row.act, get_page_versions: o.versions || V }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n)
    if (n === 'reject_property_page' || n === 'approve_property_page') {
      const body = JSON.parse(x.request().postData() || '{}'); st.writes.push({ n, body })
      if (o.refuse) return x.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ code: '22023', message: o.refuse, details: 'blocker=superseded in client.' + n, hint: null }) })
      const v = V.find((y) => y.page_id === body.p_page_id)
      return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, page_id: body.p_page_id, version: v && v.version }) })
    }
    if (x.request().method() !== 'POST' && x.request().method() !== 'GET') { st.writes.push({ n, method: x.request().method() }); return x.fulfill({ status: 403, body: '{}' }) }
    if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) })
    return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' }) })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route(/maps\.googleapis\.com|places\.googleapis\.com/, (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) t = t.split(from).join(to); return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + '/property/' + PID)
  await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent === 'Contacts'), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(2500)
  return { ctx, p, st }
}
const btnBy = (p, re) => p.evaluate((src) => { const re = new RegExp(src); const b = [...document.querySelectorAll('button')].filter((x) => re.test((x.getAttribute('aria-label') || x.textContent || '').trim()) && x.offsetParent !== null); return b.map((x) => { const r = x.getBoundingClientRect(), cs = getComputedStyle(x); return { text: x.textContent.trim(), aria: x.getAttribute('aria-label'), x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height), color: cs.color, border: cs.borderTopColor, bg: cs.backgroundColor } }) }, re.source)

// 1. COUNTS BAR (1440): the lock icon, its tooltip, the centered row, the arrow and the glow
{
  const { ctx, p, st } = await open(1440)
  const lock = await p.evaluate(() => { const b = [...document.querySelectorAll('button')].find((x) => x.getAttribute('aria-label') === 'Unlock to change for this page'); if (!b) return null
    const svg = b.querySelector('svg'), r = b.getBoundingClientRect(), fills = svg ? [...svg.querySelectorAll('*')].map((e) => getComputedStyle(e).fill).concat(getComputedStyle(svg).fill) : []
    let row = b.parentElement; while (row && !/\bflex\b/.test(row.className)) row = row.parentElement
    const kids = row ? [...row.children].map((c) => c.getBoundingClientRect()) : [], left = kids.length ? Math.min(...kids.map((k) => k.left)) : 0, right = kids.length ? Math.max(...kids.map((k) => k.right)) : 0, rr = row ? row.getBoundingClientRect() : null
    return { text: b.textContent.trim(), w: Math.round(r.width), h: Math.round(r.height), filled: fills.some((f) => f && f !== 'none' && !/rgba\(0, 0, 0, 0\)/.test(f)), color: getComputedStyle(b).color, jc: row ? getComputedStyle(row).justifyContent : null,
      gapL: rr ? Math.round(left - rr.left) : null, gapR: rr ? Math.round(rr.right - right) : null } })
  ok(lock && lock.text === '' || (lock && !/Unlock/.test(lock.text)), 'counts bar: "Unlock to change for this page" is an icon button, no words', lock && lock.text)
  ok(lock && lock.filled && /rgb\(24, 24, 27\)/.test(lock.color), 'counts bar: the lock icon is filled black (#18181b)', lock && { filled: lock.filled, color: lock.color })
  ok(lock && lock.w === lock.h && lock.h >= 34 && lock.h <= 42, 'counts bar: the button is square, 36 to 40px', lock && { w: lock.w, h: lock.h })
  ok(lock && lock.jc === 'center' && Math.abs(lock.gapL - lock.gapR) <= 4, 'counts bar: the row is centered', lock && { jc: lock.jc, gapL: lock.gapL, gapR: lock.gapR })
  await p.locator('button[aria-label="Unlock to change for this page"]').first().hover(); await p.waitForTimeout(700)
  const tip = await p.evaluate(() => { const t = [...document.querySelectorAll('[role="tooltip"], [data-radix-popper-content-wrapper]')].map((e) => e.textContent.trim()); return t })
  ok(tip.some((t) => t === 'Unlock to change for this page'), 'counts bar: hovering shows the tooltip "Unlock to change for this page"', tip)
  await p.screenshot({ path: `${out}/1440_counts_bar.png`, clip: { x: 0, y: 0, width: 1440, height: 260 } })
  // unlocked: the same button with an open lock and "Lock"; pressing it locks again (local state, nothing written)
  await p.locator('button[aria-label="Unlock to change for this page"]').first().click(); await p.waitForTimeout(500)
  const ask = await p.evaluate(() => (document.querySelector('[role="alertdialog"], [role="dialog"]') || {}).textContent || '')
  ok(/Unlock these values\?/.test(ask), 'counts bar: the lock still asks "Unlock these values?" first', ask.slice(0, 120))
  await p.locator('[role="alertdialog"] button, [role="dialog"] button', { hasText: /^Unlock$/ }).first().click().catch(() => {}); await p.waitForTimeout(500)
  const un = await p.evaluate(() => { const b = [...document.querySelectorAll('button')].find((x) => x.getAttribute('aria-label') === 'Lock'); return b ? { open: !!b.querySelector('svg.lucide-lock-open, svg[class*="lock-open"]'), text: b.textContent.trim() } : null })
  ok(un && un.open && !/^Lock$/.test(un.text), 'counts bar: unlocked, the button shows an open lock named "Lock"', un)
  if (un) { await p.locator('button[aria-label="Lock"]').first().click(); await p.waitForTimeout(400) }
  ok(await p.locator('button[aria-label="Unlock to change for this page"]').count() >= 1, 'counts bar: pressing it locks again')
  // the arrow beside "Counts at the top of the page" (the side by side panel, 1280px and up)
  const arrow = p.locator('button[aria-label="Go to the counts at the top of the page"]').first()
  ok(await arrow.count() === 1, 'counts box: the up arrow is there')
  if (await arrow.count()) {
    const a = await arrow.evaluate((b) => { const r = b.getBoundingClientRect(), cs = getComputedStyle(b); const h = [...document.querySelectorAll('h3')].find((x) => /Counts at the top of the page/i.test(x.textContent)); const hr = h && h.getBoundingClientRect(); return { w: Math.round(r.width), h: Math.round(r.height), bg: cs.backgroundColor, radius: cs.borderRadius, nextToTitle: !!(hr && Math.abs((r.top + r.bottom) / 2 - (hr.top + hr.bottom) / 2) < 12 && r.left >= hr.right - 2 && r.left - hr.right < 40) } })
    ok(a.bg === 'rgb(241, 71, 20)' && a.w === a.h && a.w >= 26 && a.w <= 30 && a.nextToTitle, 'counts box: a 28px orange round button right next to the title', a)
    await arrow.scrollIntoViewIfNeeded(); await p.waitForTimeout(300)
    await arrow.click(); await p.waitForTimeout(900)
    const g = await p.evaluate(() => { const b = [...document.querySelectorAll('button')].find((x) => x.getAttribute('aria-label') === 'Unlock to change for this page'); let row = b.parentElement; while (row && !/\bflex\b/.test(row.className)) row = row.parentElement
      const glowEl = [row, row.parentElement, row.parentElement && row.parentElement.parentElement].find((e) => e && /241, 71, 20/.test(getComputedStyle(e).boxShadow))
      const top = row.getBoundingClientRect().top; return { glow: !!glowEl, inView: top >= -5 && top < innerHeight / 2, focus: !!(document.activeElement && (document.activeElement === row || row.contains(document.activeElement) || (glowEl && glowEl.contains(document.activeElement)) || document.activeElement === glowEl)) } })
    ok(g.glow && g.inView, 'counts box arrow: the page scrolls to the bar and it glows orange', g)
    ok(g.focus, 'counts box arrow: the focus moves to the bar', g)
    await p.screenshot({ path: `${out}/1440_counts_glow.png`, clip: { x: 0, y: 0, width: 1440, height: 260 } })
    await p.waitForTimeout(2600)
    const g2 = await p.evaluate(() => [...document.querySelectorAll('*')].filter((e) => /241, 71, 20, 0\.(55|35)/.test(getComputedStyle(e).boxShadow)).length)
    ok(g2 === 0, 'counts box arrow: the glow is gone after about 2 seconds', g2)
  }
  ok(st.writes.length === 0, 'counts: nothing was written', st.writes)
  await ctx.close()
}
// 2. REVIEW SCREEN (1440 and 390): Reject left of Approve, the dialog, the call, the notice; the box lists what v2 fills in
for (const w of [1440, 390]) {
  const { ctx, p, st } = await open(w)
  await p.locator('button:visible', { hasText: /^Review version 2$/ }).first().click(); await p.waitForTimeout(1500)
  const bs = await btnBy(p, /^(Reject|Approve version 2)$/)
  const rej = bs.find((b) => b.text === 'Reject'), app = bs.find((b) => b.text === 'Approve version 2')
  ok(!!rej, `${w}: review shows Reject`, bs.map((b) => b.text))
  if (w >= 768) ok(rej && app && rej.x + rej.w <= app.x && Math.abs(rej.y - app.y) < 4, `${w}: Reject sits immediately left of Approve`, { rej, app })
  ok(rej && rej.color === 'rgb(185, 28, 28)' && rej.border === 'rgb(254, 202, 202)' && /255, 255, 255/.test(rej.bg), `${w}: Reject is white with red text and a pale red border`, rej && { color: rej.color, border: rej.border, bg: rej.bg })
  ok(rej && (w >= 768 ? rej.h === 36 : rej.h >= 44), `${w}: Reject is ${w >= 768 ? '36' : '44'}px high`, rej && rej.h)
  const box = await p.evaluate(() => { const h = [...document.querySelectorAll('h3')].find((x) => /^What this version fills in$/.test(x.textContent.trim())); const c = h && h.parentElement; return c ? { line: [...c.querySelectorAll('p')].map((x) => x.textContent.trim()), items: [...c.querySelectorAll('li')].map((x) => x.textContent.trim()) } : null })
  const v2 = V.find((v) => v.version === 2)
  ok(box && box.line.some((t) => t === 'Nothing is live yet, so this lists everything on version 2.') && factLines(v2.content).every((l) => box.items.some((i) => i.startsWith(l + ':'))), `${w}: the review box lists what version 2 fills in`, box)
  await p.screenshot({ path: `${out}/${w}_review.png` })
  await p.locator('button:visible', { hasText: /^Reject$/ }).first().click(); await p.waitForTimeout(600)
  const d = await p.evaluate(() => { const dl = [...document.querySelectorAll('[role="alertdialog"], [role="dialog"]')].pop(); if (!dl) return null
    const btn = (t) => [...dl.querySelectorAll('button')].find((b) => b.textContent.trim() === t)
    return { text: dl.textContent.replace(/\s+/g, ' ').trim(), focus: document.activeElement && document.activeElement.textContent.trim(), rejDisabled: btn('Reject version 2') ? btn('Reject version 2').disabled : null, ta: !!dl.querySelector('textarea'), max: dl.querySelector('textarea') && dl.querySelector('textarea').maxLength } })
  ok(d && /Reject version 2\?/.test(d.text) && /The site file stays as it is\. Version 2 stays in Activity, marked Rejected with your reason\./.test(d.text) && /Why are you rejecting it\?/.test(d.text) && /Required, 3 to 500 characters\./.test(d.text), `${w}: the reject dialog says what happens and asks why`, d && d.text)
  ok(d && d.focus === 'Keep it' && d.rejDisabled === true && d.ta && d.max === 500, `${w}: "Keep it" has the focus; Reject waits for a reason; 500 characters at most`, d)
  await p.locator('textarea').last().fill('  ab '); await p.waitForTimeout(150)
  const dis2 = await p.evaluate(() => [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === 'Reject version 2').disabled)
  ok(dis2 === true, `${w}: two characters keep Reject disabled`)
  await p.locator('textarea').last().fill('  The cleanouts count is wrong.  '); await p.waitForTimeout(150)
  await p.screenshot({ path: `${out}/${w}_reject_dialog.png` })
  await p.locator('button:visible', { hasText: /^Reject version 2$/ }).last().click(); await p.waitForTimeout(1800)
  const wr = st.writes.filter((x) => x.n === 'reject_property_page')
  ok(wr.length === 1 && wr[0].body.p_page_id === V.find((v) => v.version === 2).page_id && wr[0].body.p_reason === 'The cleanouts count is wrong.', `${w}: one reject call, for version 2, with the trimmed reason`, wr)
  const after = await p.evaluate(() => ({ dialog: !!document.querySelector('[role="alertdialog"]'), notice: [...document.querySelectorAll('[role="status"]')].map((e) => e.textContent.trim()).filter(Boolean) }))
  ok(!after.dialog && after.notice.some((t) => /Version 2 rejected\./.test(t)), `${w}: the dialog closes and "Version 2 rejected." shows`, after)
  ok(st.calls.filter((c) => c === 'get_page_builder').length >= 2, `${w}: the page data is read again after the reject`)
  ok(!st.writes.some((x) => x.n === 'approve_property_page' || x.method), `${w}: nothing else was written`, st.writes)
  await ctx.close()
}
// 3. a refusal shows the server's sentence in the dialog and keeps the reason
{
  const { ctx, p, st } = await open(1440, { refuse: 'A later version of this page is already live, so this one can no longer be rejected.' })
  await p.locator('button:visible', { hasText: /^Review version 2$/ }).first().click(); await p.waitForTimeout(1500)
  await p.locator('button:visible', { hasText: /^Reject$/ }).first().click(); await p.waitForTimeout(500)
  await p.locator('textarea').last().fill('Wrong count'); await p.locator('button:visible', { hasText: /^Reject version 2$/ }).last().click(); await p.waitForTimeout(1500)
  const d = await p.evaluate(() => { const dl = document.querySelector('[role="alertdialog"]'); return dl ? { text: dl.textContent, ta: dl.querySelector('textarea').value } : null })
  ok(d && /A later version of this page is already live, so this one can no longer be rejected\./.test(d.text) && d.ta === 'Wrong count', 'refusal: the sentence shows in the dialog and the reason stays', d && d.text.slice(0, 200))
  await ctx.close()
}
// 4. ACTIVITY: both versions waiting with Approve and Reject; Approve through the confirm; version 1 lists what it filled in
{
  const { ctx, p, st } = await open(1440)
  await p.locator('button', { hasText: /^Activity$/ }).first().click(); await p.waitForTimeout(1500)
  const items = await p.evaluate(() => [...document.querySelectorAll('[data-version-item]')].map((x) => x.textContent.replace(/\s+/g, ' ').trim()).filter((t) => /^Version \d/.test(t)))
  ok(items.length === 2 && items.every((t) => /Waiting for approval/.test(t)), 'Activity: both versions read "Waiting for approval"', items)
  const head = async () => p.evaluate(() => { const h = document.querySelector('[data-version-detail] [data-version-head]'); return h ? [...h.querySelectorAll('button')].map((b) => b.textContent.trim()) : null })
  ok(JSON.stringify(await head()) === JSON.stringify(['Reject', 'Approve version 2']), 'Activity v2: Reject and Approve version 2 in the title row', await head())
  await p.screenshot({ path: `${out}/1440_activity_v2.png` })
  await p.locator('[data-version-item="1"]').click(); await p.waitForTimeout(800)
  ok(JSON.stringify(await head()) === JSON.stringify(['Reject', 'Approve version 1']), 'Activity v1: the older waiting version can be decided too', await head())
  const v1 = await p.evaluate(() => { const det = document.querySelector('[data-version-detail]'); const h = [...det.querySelectorAll('p')].find((x) => /^What version 1 filled in$/i.test(x.textContent.trim())); const ul = h && h.nextElementSibling; return { heading: !!h, first: /First version/.test(det.textContent), items: ul ? [...ul.querySelectorAll('li')].map((x) => x.textContent.trim()) : [] } })
  const v1c = V.find((v) => v.version === 1).content
  ok(v1.heading && !v1.first && factLines(v1c).every((l) => v1.items.some((i) => i.startsWith(l + ':'))) && v1.items.some((i) => /photo/.test(i)), 'Activity v1: "What version 1 filled in" lists its facts and photos', v1)
  await p.screenshot({ path: `${out}/1440_activity_v1.png` })
  await p.locator('[data-version-detail] [data-version-head] button', { hasText: /^Approve version 1$/ }).click(); await p.waitForTimeout(600)
  const conf = await p.evaluate(() => { const d = document.querySelector('[role="alertdialog"]'); return d ? d.textContent.replace(/\s+/g, ' ') : null })
  ok(conf && /Approve version 1\?/.test(conf) && /It goes live on the site file right away\./.test(conf), 'Activity approve: the same confirm as the review', conf)
  await p.locator('[role="alertdialog"] button', { hasText: /^Approve$/ }).click(); await p.waitForTimeout(1800)
  const wa = st.writes.filter((x) => x.n === 'approve_property_page')
  ok(wa.length === 1 && wa[0].body.p_page_id === V.find((v) => v.version === 1).page_id, 'Activity approve: one approve call, for version 1', wa)
  const m = await p.evaluate(() => ({ open: !!document.querySelector('[data-activity-dialog]'), status: [...document.querySelectorAll('[data-activity-dialog] [role="status"]')].map((e) => e.textContent.trim()) }))
  ok(m.open && m.status.some((t) => /Version 1 approved\./.test(t)), 'Activity approve: the modal stays open with "Version 1 approved."', m)
  ok(st.calls.filter((c) => c === 'get_page_versions').length >= 2 && st.calls.filter((c) => c === 'get_property_activity').length >= 2, 'Activity approve: versions and activity are read again')
  await ctx.close()
}
// 5. a REJECTED version, an own version (approve blocker sentence) and an approver who may only reject
{
  const vs = clone(V)
  vs[0] = { ...vs[0], status: 'rejected', can_approve: false, approve_blocker: null, can_reject: false, rejected_at: '2026-10-21T20:05:00+00:00', rejected_by_name: 'Diego', reject_reason: 'The cleanouts count is wrong.' }
  vs[1] = { ...vs[1], can_approve: false, approve_blocker: 'You submitted this version, so another person has to approve it.', can_reject: true }
  const act = clone(row.act); act.unshift({ at: '2026-10-21T20:05:00+00:00', kind: 'page_rejected', who: 'Diego', version: 2, intake_id: null, text: 'Version 2 of the site file rejected by Diego: The cleanouts count is wrong.' })
  const { ctx, p } = await open(1440, { versions: vs })
  await p.route(SB + '/rest/v1/rpc/get_property_activity', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(act) }))
  await p.locator('button', { hasText: /^Activity$/ }).first().click(); await p.waitForTimeout(1500)
  await p.locator('[data-version-item="2"]').click(); await p.waitForTimeout(700)
  const d = await p.evaluate(() => { const it = document.querySelector('[data-version-item="2"]'), det = document.querySelector('[data-version-detail]'), dts = [...det.querySelectorAll('dt')].map((x) => x.textContent.trim()), dds = [...det.querySelectorAll('dd')].map((x) => x.textContent.trim())
    const badge = it.querySelector('[data-badge]'); const cs = badge && getComputedStyle(badge)
    return { item: it.textContent.replace(/\s+/g, ' '), badge: badge && badge.textContent.trim(), color: cs && cs.color, bg: cs && cs.backgroundColor, dts, dds, buttons: [...det.querySelectorAll('[data-version-head] button')].map((b) => b.textContent.trim()), events: det.textContent.includes('rejected by Diego') } })
  ok(d.badge === 'Rejected' && d.color === 'rgb(185, 28, 28)' && d.bg === 'rgb(254, 242, 242)', 'Activity rejected: a red "Rejected" badge', d)
  ok(d.dts.includes('Rejected by') && d.dts.includes('Reason') && !d.dts.includes('Checked by') && d.dds.some((x) => /^Diego, /.test(x)) && d.dds.includes('The cleanouts count is wrong.'), 'Activity rejected: "Rejected by" and "Reason" rows, no "Checked by"', { dts: d.dts, dds: d.dds })
  ok(d.buttons.length === 0 && !d.events, 'Activity rejected: no buttons, and the page_rejected event is not listed in its groups', d)
  await p.screenshot({ path: `${out}/1440_activity_rejected.png` })
  await p.locator('[data-version-item="1"]').click(); await p.waitForTimeout(700)
  const o = await p.evaluate(() => { const det = document.querySelector('[data-version-detail]'); return { buttons: [...det.querySelectorAll('[data-version-head] button')].map((b) => b.textContent.trim()), blocker: det.textContent.includes('You submitted this version, so another person has to approve it.') } })
  ok(JSON.stringify(o.buttons) === JSON.stringify(['Reject']) && o.blocker, 'Activity own version: Reject only, and the sentence instead of Approve', o)
  await ctx.close()
}
await browser.close()
console.log(`${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
