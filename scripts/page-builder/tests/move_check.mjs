// The Picture Planner move check (Ops Portal move plan, step 9). The same checks run on the old host (the control, the code
// that has been live) and on the portal (PLANNER_BASE=http://localhost:8080/planner or https://ops.unclogme.app/planner):
//   A. access: View sees the builder with nothing to submit; None reads nothing and is refused in words.
//   B. a waiting form's link is revealed ONCE per view, also across the shell's access re-check on coming back to the tab.
//   C. the Forms list is not re-read while its row menu is open (portal only: the old list has no menu), and is once it closes.
//   D. leaving the builder with an unsaved change asks first, and staying keeps the page.
//   E. a full-screen layer (the Site file preview) covers the portal's sidebar and header.
// Real replies read in SQL as Fred (get_page_builder for 112-YA 1164, form 1038 shown as waiting, the forms list); sign-in
// faked; every write is stubbed and recorded: nothing is written. Codes and links are fake.
//   node scripts/page-builder/tests/move_check.mjs <outdir>
import fs from 'node:fs'
import { createRequire } from 'node:module'
import { H, R, PORTAL, seedSession } from './host.mjs'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms, client.get_property_activity(1164) as act, client.get_page_versions(1164) as versions, client.get_intake(1038) as c, client.list_intake_forms() as list;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
if (!row || !row.pb || !row.c || row.c.state !== 'cancelled' || !row.list) { console.log('FAIL fixture: 1164 page builder, form 1038 (cancelled) and the forms list :: ' + ((r && r.message) || '')); process.exit(1) }
const clone = (x) => JSON.parse(JSON.stringify(x))
const AWAIT = clone(row.c); AWAIT.state = 'awaiting'
const LINK = { ok: true, intake_id: 1038, url: 'https://planner.unclogme.app/intake#code=FAKE0000FAKE0000', expires_at: AWAIT.expires_at }
const SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url'), exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const ACCESS = (level, forms = 'no') => ({ employee_id: 1, group: 'admin', me: { full_name: 'Visual Check', color_hex: null, photo_path: null }, apps: [{ app: 'picture_planner', name: 'Picture Planner', parent: null, mode: 'on', level }, { app: 'pp_forms', name: 'See their assigned forms', parent: 'picture_planner', mode: 'on', level: forms }, { app: 'pp_approve', name: 'Approve site files', parent: 'picture_planner', mode: 'on', level: 'yes' }] })
const READS = ['get_page_builder', 'get_page_builder_forms', 'get_property_activity', 'get_page_versions', 'get_intake', 'get_intake_compare', 'list_intake_forms', 'v_intake_submissions', 'page_builder_list', 'get_intake_link']
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './move_check_shots'; fs.mkdirSync(out, { recursive: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 300)}`) }
const tag = PORTAL ? 'portal' : 'old host'

async function open(path, o = {}) {
  const ctx = await browser.newContext({ viewport: { width: o.w || 1440, height: 900 } })
  if (o.clock) await ctx.clock.install()
  if (o.refuseDraft) await ctx.addInitScript(() => { const set = Storage.prototype.setItem; Storage.prototype.setItem = function (k, v) { if (String(k).startsWith('pp-draft')) throw new DOMException('full', 'QuotaExceededError'); return set.call(this, k, v) } })
  await seedSession(ctx, session, user)
  const p = await ctx.newPage()
  const st = { calls: [], writes: [], errors: [] }
  p.on('pageerror', (e) => { if (!/Google Maps/.test(String(e))) st.errors.push(String(e).slice(0, 200)) })
  const replies = { get_my_access: o.access || ACCESS('edit'), get_page_builder: row.pb, get_page_builder_forms: row.forms, get_property_activity: row.act, get_page_versions: row.versions || [], get_intake: AWAIT, list_intake_forms: row.list, get_intake_link: LINK }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => {
    const q = x.request(), n = new URL(q.url()).pathname.split('/').pop(); st.calls.push(n)
    if (!READS.includes(n) && !['get_my_access', 'portal_waiting'].includes(n)) { st.writes.push(n); return x.fulfill({ status: 403, contentType: 'application/json', body: '{}' }) }
    if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) })
    return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' })
  })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route(SB + '/functions/v1/**', (x) => { st.writes.push('fn'); return x.abort() })
  await p.route(/maps\.googleapis\.com|places\.googleapis\.com/, (x) => x.abort())
  await p.goto(H + R + path)
  if (o.wait) await p.waitForFunction(o.wait, null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(o.settle ?? 2500)
  return { ctx, p, st }
}
const count = (st, n) => st.calls.filter((c) => c === n).length
const builderReady = () => [...document.querySelectorAll('h3')].some((h) => h.textContent === 'Contacts')
const btn = (p, re) => p.evaluate((src) => [...document.querySelectorAll('button')].filter((b) => new RegExp(src).test(b.textContent.trim()) && b.offsetParent !== null).map((b) => ({ t: b.textContent.trim(), disabled: b.disabled || b.getAttribute('aria-disabled') === 'true' })), re.source)

// A. access
{
  const { ctx, p, st } = await open('/property/1164', { access: ACCESS('view'), wait: builderReady })
  const sub = await btn(p, /^Submit( for approval)?$/)
  ok(await p.evaluate(builderReady), `${tag} A view: the builder opens`)
  ok(sub.length === 0 || sub.every((b) => b.disabled), `${tag} A view: nothing to submit (absent or disabled)`, sub)
  ok(st.writes.length === 0, `${tag} A view: nothing written`, st.writes)
  await p.screenshot({ path: `${out}/A_view_${PORTAL ? 'portal' : 'old'}.png` })
  await ctx.close()
}
for (const path of ['/property/1164', '/forms']) {
  const { ctx, p, st } = await open(path, { access: ACCESS('none') })
  const t = await p.evaluate(() => document.body.textContent.replace(/\s+/g, ' '))
  const reads = st.calls.filter((c) => READS.includes(c))
  ok(reads.length === 0, `${tag} A none ${path}: no Picture Planner data is read`, reads)
  ok(/access/i.test(t) && !/Contacts/.test(t), `${tag} A none ${path}: a refusal in words, no page`, t.slice(0, 200))
  await ctx.close()
}

// B. the link is revealed once per view, across the access re-check on coming back to the tab
{
  const { ctx, p, st } = await open('/forms/1038', { clock: true, wait: () => /FAKE0000/.test(document.body.textContent) || /Could not get the link/.test(document.body.textContent) })
  const shown = await p.evaluate(() => document.body.textContent.includes('FAKE0000FAKE0000'))
  const n0 = count(st, 'get_intake_link'), a0 = count(st, 'get_my_access')
  if (process.env.DEBUG) console.log('DEBUG B ' + st.calls.join(','))
  ok(shown && n0 === 1, `${tag} B the waiting form shows its link after one reveal`, { shown, reveals: n0 })
  await p.clock.fastForward(61_000)
  await p.evaluate(() => { window.dispatchEvent(new Event('blur')); window.dispatchEvent(new Event('focus')) })
  await p.clock.fastForward(2_000); await p.waitForTimeout(1500)
  const a1 = count(st, 'get_my_access')
  ok(!PORTAL || a1 > a0, `${tag} B the shell re-checked access on coming back (portal only)`, { before: a0, after: a1 })
  ok(count(st, 'get_intake_link') === 1, `${tag} B still one reveal after the re-check`, count(st, 'get_intake_link'))
  ok(st.writes.length === 0, `${tag} B nothing written`, st.writes)
  await ctx.close()
}

// C. the Forms list is not re-read under an open row menu, and is again once it closes (portal: F3's menu)
if (PORTAL) {
  const { ctx, p, st } = await open('/forms', { clock: true, wait: () => !!document.querySelector('button[aria-label^="More"], button[aria-haspopup="menu"]') })
  const trig = p.locator('main button[aria-haspopup="menu"]').first()
  ok(await trig.count() === 1, `${tag} C a row has its menu button`)
  const n0 = count(st, 'list_intake_forms')
  await trig.click(); await p.waitForTimeout(400)
  const open1 = await p.evaluate(() => !!document.querySelector('[role="menu"]'))
  await p.clock.fastForward(130_000); await p.waitForTimeout(800)
  const n1 = count(st, 'list_intake_forms')
  ok(open1 && n1 === n0, `${tag} C two minutes with the menu open: no re-read`, { open: open1, before: n0, after: n1 })
  await p.keyboard.press('Escape'); await p.waitForTimeout(300)
  await p.clock.fastForward(65_000); await p.waitForTimeout(800)
  const n2 = count(st, 'list_intake_forms')
  ok(n2 > n1, `${tag} C the control: with the menu closed the list is re-read`, { closed: n1, after: n2 })
  await ctx.close()
} else console.log('SKIP C on the old host: its Forms list has no row menu')

// D. the leave guard. The builder keeps a draft in the browser, so it asks before leaving only when that draft could not be
// saved (unsaved = dirty && draft failed). With the draft saved it lets you go; with the draft refused it asks, and Stay stays.
for (const refuse of [false, true]) {
  const { ctx, p, st } = await open('/property/1164', { wait: builderReady, refuseDraft: refuse })
  const field = p.locator('main textarea:visible').first()   // a fact on the page (the first text input is the map's address search, not part of the draft)
  const had = await field.count()
  if (had) { await field.click(); await p.keyboard.type(' move check'); await p.waitForTimeout(1500) }
  ok(had === 1, `${tag} D${refuse ? ' draft refused' : ''}: there is a field to change`)
  if (process.env.DEBUG) console.log("DEBUG " + JSON.stringify([await field.evaluate((e) => ({ tag: e.tagName, name: e.getAttribute('aria-label') || e.getAttribute('placeholder') || e.id, value: e.value.slice(-20) })), await p.evaluate(() => ({ keys: Object.keys(localStorage), warn: /draft|could not save|not saved/i.test(document.body.textContent) ? (document.body.textContent.match(/[^.]{0,60}(draft|not saved)[^.]{0,60}/i) || [""])[0] : null }))]))
  const link = p.locator('a[href$="/forms"]:visible').first()
  ok(await link.count() === 1, `${tag} D${refuse ? ' draft refused' : ''}: a link to Forms is on the page`)
  if (await link.count()) { await link.click(); await p.waitForTimeout(900) }
  const d = await p.evaluate(() => { const dl = [...document.querySelectorAll('[role="alertdialog"], [role="dialog"]')].pop(); return { dialog: dl ? dl.textContent.replace(/\s+/g, ' ').trim().slice(0, 160) : null, path: location.pathname } })
  if (!refuse) { ok(!d.dialog && /\/forms$/.test(d.path), `${tag} D draft saved: leaving does not ask (the draft keeps the change)`, d); await ctx.close(); continue }
  ok(!!d.dialog && /\/property\/1164$/.test(d.path), `${tag} D draft refused: leaving asks first and the page stays`, d)
  await p.screenshot({ path: `${out}/D_leave_${PORTAL ? 'portal' : 'old'}.png` })
  const stay = p.locator('[role="alertdialog"] button, [role="dialog"] button', { hasText: /^(Stay|Keep editing|Cancel)/ }).first()
  if (await stay.count()) { await stay.click(); await p.waitForTimeout(500) }
  const after = await p.evaluate(() => ({ path: location.pathname, dialog: !!document.querySelector('[role="alertdialog"]') }))
  ok(/\/property\/1164$/.test(after.path) && !after.dialog, `${tag} D draft refused: staying closes the question and keeps the page`, after)
  ok(st.writes.length === 0, `${tag} D nothing written`, st.writes)
  await ctx.close()
}

// E. a full-screen layer covers the shell (the sidebar sits at x < 228 from 1280 wide)
{
  const { ctx, p } = await open('/property/1164', { wait: builderReady })
  await p.locator('button:visible', { hasText: /^View site file$/ }).first().click({ timeout: 5000 }).catch(() => {})
  await p.waitForTimeout(1200)
  const e = await p.evaluate(() => { const d = [...document.querySelectorAll('[role="dialog"][aria-modal="true"]')].pop(); if (!d) return null
    const pts = [[60, 450], [700, 20], [1400, 20]].map(([x, y]) => { const h = document.elementFromPoint(x, y); return !!h && (d.contains(h) || !!h.closest('[data-radix-portal], [role="dialog"]') || getComputedStyle(h).position === 'fixed') })
    const nav = document.querySelector('aside, nav[aria-label]'); const hitNav = nav ? [[60, 450]].some(([x, y]) => nav.contains(document.elementFromPoint(x, y))) : false
    return { pts, hitNav } })
  ok(!!e && e.pts.every(Boolean) && !e.hitNav, `${tag} E the Site file preview covers the sidebar and the header`, e)
  await p.screenshot({ path: `${out}/E_layer_${PORTAL ? 'portal' : 'old'}.png` })
  await ctx.close()
}

await browser.close()
console.log(`\n${pass} passed, ${fail} failed`)
process.exitCode = fail ? 1 : 0
