// LIVE Page Builder, property 1164, real data read in SQL as Fred's claims, edited per scenario. Sign-in faked, every
// RPC stubbed, nothing written. Checks batch M3 (2026-09-27): the address box above the builder map, and the
// developer-approval wording. ADDRESS_SEARCH=blocked while the Planner key does not allow Places API (New).
//   node scripts/page-builder/tests/address_approval.mjs <outdir>
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms;`)
const row = r[r.length - 1]
const L = Number(row.pb.property.lat), G = Number(row.pb.property.lng)
const blocked = process.env.ADDRESS_SEARCH === 'blocked'
// a pending version made by the viewer, who is a self-approver
const SELF = JSON.parse(JSON.stringify({ pb: row.pb, forms: row.forms }))
SELF.pb.pending = { ...SELF.pb.live, page_id: 999998, version: (SELF.pb.newest_version || 1) + 1, submitted_by_name: 'Fred', mine: true, approved_at: null, approved_by_name: null }
SELF.pb.newest_version = SELF.pb.pending.version
SELF.pb.can_approve = true; SELF.pb.approve_blocker = null; SELF.pb.can_self_approve = true
// the same page for a viewer who is not a self-approver
const OTHER = JSON.parse(JSON.stringify(SELF)); OTHER.pb.can_self_approve = false; OTHER.pb.can_approve = false
OTHER.pb.approve_blocker = 'You submitted this version, so another person has to approve it.'
const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 400)}`) }
const out = process.argv[2] || './addr_shots'; fs.mkdirSync(out, { recursive: true })
const calls = []
async function open(w, data) {
  const ctx = await browser.newContext({ viewport: { width: w, height: 900 } })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const replies = { get_page_builder: data.pb, get_page_builder_forms: data.forms, get_property_activity: [] }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); calls.push(n); if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) }); return x.fulfill({ status: 404, body: '{}' }) })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.goto(H + '/property/1164')
  await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent === 'Contacts'), null, { timeout: 30000 })
  await p.waitForTimeout(3500)
  return { ctx, p }
}
const box = (p) => p.locator('input[placeholder="Type an address to move the map"]').first()
const mapCenter = (p) => p.evaluate(() => { const b = [...document.querySelectorAll('button')].find((x) => /GT Location/.test(x.textContent)); const w = b && b.closest('.space-y-2'); const g = w && w.querySelector('.gm-style'); return g ? g.getBoundingClientRect().toJSON() : null })

for (const w of [390, 1440]) {
  const { ctx, p } = await open(w, { pb: row.pb, forms: row.forms })
  const b = box(p)
  ok(await b.isVisible().catch(() => false), `${w}: the address box is above the map`)
  const bb = await b.boundingBox().catch(() => null)
  ok(bb && (w < 768 ? bb.height >= 44 : bb.height <= 40), `${w}: the box is ${w < 768 ? '44px or more on a phone' : 'the laptop size'}`, bb && Math.round(bb.height))
  const draft0 = await p.evaluate(() => { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k.startsWith('pp-draft:')) return localStorage.getItem(k) } return null })
  if (await b.isVisible().catch(() => false)) { await b.fill('650 NW 33rd St Miami'); await p.waitForTimeout(4000) }
  const sug = await p.locator('button', { hasText: /Miami/ }).filter({ has: p.locator('span, div, p') }).count()
  const status = await p.evaluate(() => [...document.querySelectorAll('[role="status"]')].map((x) => x.textContent.trim()).filter(Boolean))
  if (blocked) {
    ok(status.some((t) => t === 'Address search is not available right now. Move the map by hand.'), `${w}: a refused search says so in words`, status)
  } else {
    ok(sug >= 1, `${w}: typing an address offers suggestions`, { sug, status })
    await b.press('Enter').catch(() => {}); await p.waitForTimeout(3500)
    const st2 = await p.evaluate(() => [...document.querySelectorAll('[role="status"]')].map((x) => x.textContent.trim()).filter(Boolean))
    ok(st2.includes('Map moved to that address. Now place the pins.'), `${w}: Enter picks the first and moves the map`, st2)
  }
  const draft1 = await p.evaluate(() => { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k.startsWith('pp-draft:')) return localStorage.getItem(k) } return null })
  const pins = (s) => { try { return JSON.stringify((JSON.parse(s).content || {}).site_map || null) } catch { return null } }
  ok(pins(draft1) === pins(draft0), `${w}: searching changed no pin or arrow in the draft`)
  ok(!(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth)), `${w}: no sideways scroll`)
  await b.scrollIntoViewIfNeeded({ timeout: 3000 }).catch(() => {}); await p.screenshot({ path: `${out}/address_${w}.png` })
  await ctx.close()
}
const typeInNotes = async (p) => { const ok2 = await p.evaluate(() => { const tas = [...document.querySelectorAll('textarea')].filter((x) => x.offsetParent !== null); const ta = tas.find((x) => /Shared access notes/i.test((x.closest('div')?.parentElement?.textContent) || '')) || tas[0]; if (!ta) return false; ta.scrollIntoView({ block: 'center' }); ta.focus(); return true }); if (ok2) { await p.keyboard.press('End'); await p.keyboard.type(' x') } await p.waitForTimeout(900); return ok2 }
{ // developer approval wording (opens the review; the Submit confirm is only opened, never confirmed)
  const openReview = async (p) => { await p.locator('button', { hasText: /^Review version \d+$/ }).first().click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(1200); return p.evaluate(() => document.body.textContent) }
  const a = await open(1440, SELF)
  const t = await openReview(a.p)
  ok(/Approve my own version \d+ \(developer approval\)/.test(t), 'self-approver: in the review, the approve button says it is their own version', (t.match(/Approve[^.?]{0,50}/g) || []).slice(0, 3))
  await a.p.keyboard.press('Escape'); await a.p.waitForTimeout(600)
  await typeInNotes(a.p)
  await a.p.locator('button', { hasText: /^Submit for approval$/ }).click({ timeout: 4000 }).catch(() => {}); await a.p.waitForTimeout(800)
  const t2 = await a.p.evaluate(() => document.body.textContent)
  ok(/You can approve it yourself right after \(developer approval\)\./.test(t2) && !/\(not you\) approves it/.test(t2), 'self-approver: the Submit confirm says they can approve it themselves', (t2.match(/Submit version[^]{0,160}/) || [])[0])
  await a.p.locator('button', { hasText: /^Keep editing$/ }).click().catch(() => {})
  await a.ctx.close()
  const o = await open(1440, OTHER)
  const t3 = await openReview(o.p)
  ok(!/developer approval/.test(t3) && /You submitted this version, so another person has to approve it\./.test(t3), 'another approver: no developer wording, the blocker sentence in the review')
  await o.p.keyboard.press('Escape'); await o.p.waitForTimeout(500)
  await typeInNotes(o.p)
  await o.p.locator('button', { hasText: /^Submit for approval$/ }).click({ timeout: 4000 }).catch(() => {}); await o.p.waitForTimeout(800)
  const t4 = await o.p.evaluate(() => document.body.textContent)
  if (process.env.DEBUG_SHOT) { await o.p.screenshot({ path: process.env.DEBUG_SHOT }); console.log('DBG', JSON.stringify(await o.p.evaluate(() => ({ sub: [...document.querySelectorAll('button')].filter((b) => /Submit for approval/.test(b.textContent)).map((b) => b.disabled), foot: (document.querySelector('footer')||document.body).textContent.slice(-300), dialogs: document.querySelectorAll('[role=dialog]').length }))))}
  ok(/\(not you\) approves it before drivers see it\./.test(t4) && !/approve it yourself/.test(t4), 'another approver: the Submit confirm keeps "(not you) approves it"', (t4.match(/Submit version[^]{0,160}/) || [])[0])
  await o.p.locator('button', { hasText: /^Keep editing$/ }).click().catch(() => {})
  await o.ctx.close()
}
ok(!calls.some((n) => /approve_property_page|submit_property_page|update_property_site_map/.test(n)), 'nothing was written', [...new Set(calls)])
await browser.close()
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
