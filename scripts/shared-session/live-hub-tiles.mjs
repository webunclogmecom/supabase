// live-hub-tiles.mjs: does the LIVE Apps Hub show each person only the apps they can open? (Trello 7RbkGfON, 2026-10-28)
// Signs in with a fake session and answers every Supabase call locally (nothing reaches Supabase but the public
// signing keys), giving hr.get_my_access a canned reply per case, then reads which tiles are visible.
// The rule (Fred, 2026-10-28): an access app's tile shows when the person can open it (its mode is not 'on', or the
// level is view/edit; Picture Planner also with "See submitted forms" on); Field Portal + DUMP for every staff sign-in;
// Sales App + Coming Soon only for people with View or Edit in some app; tile order never changes.
// PASS = every case shows exactly its expected tiles and texts. Before the 2026-10-28 build the field cases FAIL.
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const HUB = process.env.HUB || 'https://hub.unclogme.app/'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')

const ALL = ['Visit Calendar', 'Admin Review', 'DERM Tracker', 'DERM Stamp Studio', 'Client App', 'Field Portal', 'DUMP Schedule', 'Sales App', 'HR App', 'Picture Planner', 'Ops Portal', 'Review Assist']
const TOP = ['hr', 'admin_review', 'client_app', 'visit_calendar', 'derm_tracker', 'stamp_studio', 'picture_planner']
const SUBS = { hr_pay: 'hr', hr_bonus: 'hr', pp_approve: 'picture_planner', pp_forms: 'picture_planner' }
// levels: { app: level } (top level: none|view|edit; switches: yes|no); modes: { app: mode } (default 'on')
function reply(id, group, levels, modes = {}, drop = []) {
  const apps = [...TOP, ...Object.keys(SUBS)].filter((a) => !drop.includes(a)).map((a) => ({
    app: a, parent: SUBS[a] ?? null, mode: modes[a] ?? 'on', level: levels[a] ?? (SUBS[a] ? 'no' : 'none'),
  }))
  return { employee_id: id, group, apps }
}
const every = (lvl) => Object.fromEntries(TOP.map((a) => [a, lvl]))
const FIELD_FORMS = ['Field Portal', 'DUMP Schedule', 'Picture Planner']
const CASES = [
  { name: 'admin, edit everywhere', who: 'Fred', group: 'admin', r: reply(2, 'admin', { ...every('edit'), pp_forms: 'yes' }), tiles: ALL, chip: 'Admin', card: false },
  { name: 'office, edit everywhere', who: 'Diego', group: 'office', r: reply(28, 'office', every('edit')), tiles: ALL, chip: 'Office', card: false },
  { name: 'office, HR App none', who: 'Aaron', group: 'office', r: reply(26, 'office', { ...every('edit'), hr: 'none' }), tiles: ALL.filter((t) => t !== 'HR App'), chip: 'Office', card: true },
  { name: 'field, see submitted forms', who: 'Fred Driver', group: 'field', r: reply(59, 'field', { pp_forms: 'yes' }), tiles: FIELD_FORMS, chip: 'Field', card: true, plannerSub: 'Submitted forms', search: 'calendar' },
  { name: 'field, no forms switch', who: 'Grecia', group: 'field', r: reply(1, 'field', {}), tiles: ['Field Portal', 'DUMP Schedule'], chip: 'Field', noApps: true },
  { name: 'field, Planner not switched on', who: 'Mark', group: 'field', r: reply(35, 'field', {}, { picture_planner: 'watch' }), tiles: FIELD_FORMS, chip: 'Field', card: true },
  { name: 'field, reply without DERM Tracker', who: 'Michael', group: 'field', r: reply(40, 'field', { pp_forms: 'yes' }, {}, ['derm_tracker']), tiles: ['DERM Tracker', ...FIELD_FORMS], chip: 'Field', card: true },
  { name: 'access check fails', who: 'Fred', group: 'admin', fail: true, tiles: [], retry: true },
]

const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let bad = 0
for (const [w, h] of [[1440, 900], [375, 812]]) for (const c of CASES) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h } }); const page = await ctx.newPage()
  const exp = Math.floor(Date.now() / 1000) + 3600, sub = '00000000-0000-4000-8000-000000000' + String(c.r?.employee_id ?? 2).padStart(3, '0')
  const mail = c.who.toLowerCase().replace(/ /g, '.') + '@unclogme.com'
  const jwt = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub, email: mail, role: 'authenticated', aud: 'authenticated', exp, aal: 'aal1' })}.${Buffer.alloc(32, 7).toString('base64url')}`
  const user = { id: sub, aud: 'authenticated', role: 'authenticated', email: mail, email_confirmed_at: '2026-01-01T00:00:00Z', app_metadata: { provider: 'email', providers: ['email'] }, user_metadata: {} }
  const seen = { access: 0, logout: 0, other: [] }
  await page.route('**/auth/v1/token**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: exp, refresh_token: 'canned', user }) }))
  await page.route('**/auth/v1/user**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await page.route('**/auth/v1/logout**', (r) => { seen.logout++; r.fulfill({ status: 204, body: '' }) })
  await page.route('**/rest/v1/**', (r) => {
    const u = r.request().url()
    if (/rpc\/get_my_access/.test(u)) {
      seen.access++
      if (c.fail && seen.access < 99) return r.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"canned failure"}' })
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(c.r) })
    }
    // a field person's own employees row is refused by the read gate in real life (403); office/admin get it
    if (/\/employees/.test(u)) return c.group === 'field'
      ? r.fulfill({ status: 403, contentType: 'application/json', body: '{"code":"42501","message":"You do not have access to any UnclogMe app."}' })
      : r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([{ id: c.r?.employee_id ?? 2, full_name: c.who, color_hex: '#14B8A6', photo_path: null }]) })
    seen.other.push(u.replace(/^.*\/rest\/v1/, '')); r.fulfill({ status: 200, contentType: 'application/json', body: '[]' })
  })
  await page.route('**/storage/v1/**', (r) => r.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await page.goto(HUB); await page.waitForTimeout(2500)
  await page.locator('input[type=email]').first().fill(mail)
  await page.locator('input[type=password]').first().fill('canned-not-a-password')
  await page.getByRole('button', { name: /^sign in$/i }).first().click()
  await page.waitForTimeout(3500)
  const read = () => page.evaluate((ALL) => {
    const vis = (el) => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' && Number(s.opacity) > 0 }
    const leaves = [...document.querySelectorAll('body *')].filter((e) => e.children.length === 0 && vis(e))
    const tiles = []
    for (const n of ALL) { const el = leaves.find((e) => e.textContent.trim() === n); if (el) tiles.push({ n, y: el.getBoundingClientRect().top, x: el.getBoundingClientRect().left }) }
    const text = document.body.innerText
    const pp = leaves.find((e) => e.textContent.trim() === 'Picture Planner')
    const ppSub = pp ? (pp.closest('a,div')?.parentElement?.innerText || pp.parentElement?.innerText || '') : ''
    const header = document.querySelector('header')
    const chip = header ? [...header.querySelectorAll('*')].map((e) => [e.textContent.trim(), e.getAttribute('aria-label') || '', e.getAttribute('title') || '']).flat().join(' | ') : ''
    return { tiles: tiles.map((t) => t.n), text, ppSub, chip, wide: document.documentElement.scrollWidth > innerWidth + 1 }
  }, ALL)
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/${w}-${c.name.replace(/[^a-z0-9]+/gi, '-')}.png`, fullPage: true })  // SHOTS=<dir>: keep a picture of each case
  let r = await read(); const fails = []
  const got = r.tiles.join(' | '), want = c.tiles.join(' | ')
  if (got !== want) fails.push(`tiles [${got}] want [${want}]`)
  if (r.wide) fails.push('sideways scroll')
  if (c.chip && !new RegExp(`\\b${c.chip}\\b`).test(r.chip)) fails.push(`no ${c.chip} chip in the header`)
  if (c.card !== undefined && /Need another app\?/.test(r.text) !== c.card) fails.push(`"Need another app?" card ${c.card ? 'missing' : 'shown'}`)
  if (c.noApps && !/No staff apps for you yet/.test(r.text)) fails.push('no "No staff apps for you yet"')
  if (!c.noApps && !c.retry && !/apps? (are|is) open for you/.test(r.text)) fails.push('no "N apps are open for you" line')
  if (c.plannerSub && !r.ppSub.includes(c.plannerSub)) fails.push(`Planner subtitle not "${c.plannerSub}"`)
  if (!/One sign-in for every UnclogMe app\./.test(r.text) && !c.retry) fails.push('old footer')
  if (c.retry) {
    if (!/We couldn.t load your apps/.test(r.text)) fails.push('no retry screen')
    if (seen.logout) fails.push('signed out on a failed check')
    const before = seen.access
    const btn = page.getByRole('button', { name: /try again/i }).first()
    if (await btn.count()) { await btn.click(); await page.waitForTimeout(1500); if (seen.access === before) fails.push('Try again did not ask again') } else fails.push('no Try again button')
  }
  if (c.search && !fails.length) {
    const box = page.getByPlaceholder(/search apps/i).first()
    await box.click(); await box.fill(c.search); await page.waitForTimeout(800)
    r = await read()
    if (r.tiles.includes('Visit Calendar')) fails.push(`search "${c.search}" found a hidden tile`)
  }
  if (seen.other.length) fails.push('unexpected requests ' + [...new Set(seen.other)].join(','))
  if (fails.length) bad++
  console.log(`${String(w).padEnd(5)}${c.name.padEnd(36)} ${fails.length ? 'FAIL  ' + fails.join('; ') : 'PASS'}`)
  await ctx.close()
}
await browser.close()
console.log(bad ? `${bad} case(s) failed` : 'all cases pass')
process.exit(bad ? 1 : 0)
