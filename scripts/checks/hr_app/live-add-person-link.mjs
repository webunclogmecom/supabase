// live-add-person-link.mjs: the LIVE HR App's Add person asks before linking a sign-in no one owns (2026-10-29).
// Signs in with a fake admin session and answers every Supabase call locally (nothing reaches Supabase, nothing is
// saved). create_employee answers like the database (Supabase 2026-10-29_1850): refused with
// details blocker=email_sign_in_unclaimed until the call carries link_sign_in: true.
//   A  Add person on an unclaimed email shows the amber panel, not the red message; the call carries no flag
//   N  "Not theirs" hides the panel and sends nothing
//   E  editing the Email field hides the panel
//   Y  "Yes, it is theirs" re-sends the same person plus link_sign_in: true and opens the Security tab
//   R  any other refusal (email_sign_in_ambiguous) shows in red, no panel
// PASS = all five at 1440 and 375. Before the 2026-10-29 build A, N, E and Y FAIL (the control).
// usage: node live-add-person-link.mjs            (DUMP=1 prints the dialog's inputs and buttons)
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const HR = process.env.HR || 'https://hr.unclogme.app/employees'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const TOP = ['hr', 'admin_review', 'client_app', 'visit_calendar', 'derm_tracker', 'stamp_studio', 'picture_planner']
const ACCESS = { employee_id: 2, group: 'admin', apps: [...TOP.map((a) => ({ app: a, parent: null, mode: 'on', level: 'edit' })),
  ...[['hr_pay', 'hr'], ['hr_bonus', 'hr'], ['pp_approve', 'picture_planner'], ['pp_forms', 'picture_planner']].map(([a, p]) => ({ app: a, parent: p, mode: 'on', level: 'yes' }))] }
const EMPLOYEES = [{ id: 2, full_name: 'Fred', status: 'ACTIVE', email: 'fred@ayache.com', access_level: 'admin', color_hex: '#3F6212', photo_path: null }]
const NAME = 'Zed Linktest', EMAIL = 'zed.linktest@example.com', PANEL = `${EMAIL} already has a sign-in, and no one in the HR App owns it`
const refuse = (code) => ({ status: 400, contentType: 'application/json', body: JSON.stringify({ code: '22023', details: `blocker=${code}`, hint: null,
  message: code === 'email_sign_in_unclaimed' ? 'That email already has a sign-in that no one in the HR App owns. Nothing was saved.'
    : 'That email matches more than one sign-in. Ask Fred to sort it out. Nothing was saved.' }) })

const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let bad = 0
const say = (w, n, ok, d) => { if (!ok) bad++; console.log(`${String(w).padEnd(5)} ${n.padEnd(44)} ${ok ? 'PASS' : 'FAIL'}  ${d}`) }

async function open(w, h, ambiguous = false) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h } }); const page = await ctx.newPage()
  const exp = Math.floor(Date.now() / 1000) + 3600, sub = '00000000-0000-4000-8000-000000000002', mail = 'fred@ayache.com'
  const jwt = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub, email: mail, role: 'authenticated', aud: 'authenticated', exp, aal: 'aal1' })}.${Buffer.alloc(32, 7).toString('base64url')}`
  const user = { id: sub, aud: 'authenticated', role: 'authenticated', email: mail, email_confirmed_at: '2026-01-01T00:00:00Z', app_metadata: { provider: 'email', providers: ['email'] }, user_metadata: {} }
  const calls = []
  await page.route('**/auth/v1/token**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: exp, refresh_token: 'canned', user }) }))
  await page.route('**/auth/v1/user**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await page.route('**/auth/v1/logout**', (r) => r.fulfill({ status: 204, body: '' }))
  await page.route('**/functions/v1/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: '{}' }))
  await page.route('**/storage/v1/**', (r) => r.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await page.route('**/rest/v1/**', (r) => {
    const u = r.request().url(), json = (b) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(b) })
    if (/rpc\/get_my_access/.test(u)) return json(ACCESS)
    if (/rpc\/create_employee/.test(u)) {
      const p = JSON.parse(r.request().postData() || '{}').p_person || {}
      calls.push(p)
      if (ambiguous) return r.fulfill(refuse('email_sign_in_ambiguous'))
      if (p.link_sign_in !== true) return r.fulfill(refuse('email_sign_in_unclaimed'))
      return json({ employee: { id: 999, full_name: p.full_name, email: p.email, status: 'ACTIVE', access_level: p.access_level || 'field' }, linked_to_jobber: false, linked_sign_in: true, jobber: { state: 'none' } })
    }
    if (/rpc\/get_jobber_people/.test(u)) return json({ synced_at: null, not_in_hr: [], differences: [] })
    if (/rpc\/get_pay_summary/.test(u)) return json([])
    if (/\/employees/.test(u)) return json(EMPLOYEES)
    return json([])
  })
  await page.goto(HR); await page.waitForTimeout(2500)
  if (await page.locator('input[type=password]').count()) {
    await page.locator('input[type=email]').first().fill(mail)
    await page.locator('input[type=password]').first().fill('canned-not-a-password')
    await page.getByRole('button', { name: /^sign in$/i }).first().click()
    await page.waitForTimeout(3500)
  }
  await page.getByRole('button', { name: /add person/i }).first().click()
  await page.waitForTimeout(800)
  const dlg = page.getByRole('dialog').first()
  if (process.env.DUMP) console.log(await dlg.evaluate((d) => ({ inputs: [...d.querySelectorAll('input')].map((i) => [i.type, i.name, i.id, i.placeholder, i.getAttribute('aria-label')]), labels: [...d.querySelectorAll('label')].map((l) => [l.textContent.trim(), l.htmlFor]), buttons: [...d.querySelectorAll('button')].map((b) => b.textContent.trim()).filter(Boolean) })))
  const field = (re) => dlg.getByLabel(re).first()
  await field(/^name/i).fill(NAME)
  await field(/^email/i).fill(EMAIL)
  const text = () => dlg.evaluate((d) => d.innerText)
  const save = () => dlg.getByRole('button', { name: /^add person$/i }).last().click()
  return { ctx, page, dlg, calls, text, save, field }
}

for (const [w, h] of [[1440, 900], [375, 812]]) {
  { // A, N, E, Y
    const t = await open(w, h)
    await t.save(); await t.page.waitForTimeout(1500)
    let txt = await t.text()
    say(w, 'A panel shows on an unclaimed sign-in', txt.includes(PANEL) && /Is it Zed['’]s\?/.test(txt) && !txt.includes('Nothing was saved'),
      `panel=${txt.includes(PANEL)} red=${txt.includes('Nothing was saved')}`)
    if (process.env.SHOTS) await t.dlg.screenshot({ path: `${process.env.SHOTS}/panel-${w}.png` })
    say(w, 'A first call carries no link_sign_in', t.calls.length === 1 && !('link_sign_in' in t.calls[0]), `calls=${JSON.stringify(t.calls)}`)
    await t.dlg.getByRole('button', { name: /^not theirs$/i }).click().catch(() => {}); await t.page.waitForTimeout(600)
    txt = await t.text()
    say(w, 'N "Not theirs" hides it, sends nothing', !txt.includes(PANEL) && t.calls.length === 1, `panel=${txt.includes(PANEL)} calls=${t.calls.length}`)
    await t.save(); await t.page.waitForTimeout(1200)
    await t.field(/^email/i).fill(EMAIL.replace('zed.', 'zed2.')); await t.page.waitForTimeout(600)
    txt = await t.text()
    say(w, 'E editing the email hides it', t.calls.length === 2 && !txt.includes('already has a sign-in'), `calls=${t.calls.length} panel=${txt.includes('already has a sign-in')}`)
    await t.field(/^email/i).fill(EMAIL); await t.save(); await t.page.waitForTimeout(1200)
    await t.dlg.getByRole('button', { name: /^yes, it is theirs$/i }).click().catch(() => {}); await t.page.waitForTimeout(2500)
    const last = t.calls[t.calls.length - 1] || {}, prev = t.calls[t.calls.length - 2] || {}
    const same = JSON.stringify({ ...last, link_sign_in: undefined }) === JSON.stringify({ ...prev, link_sign_in: undefined })
    say(w, 'Y "Yes" re-sends the same person + the flag', t.calls.length === 4 && last.link_sign_in === true && same, `calls=${t.calls.length} flag=${last.link_sign_in} same=${same}`)
    say(w, 'Y then opens the Security tab', /\/employees\/999\?.*tab=security/.test(t.page.url()), t.page.url().replace(/^https:\/\/[^/]+/, ''))
    await t.ctx.close()
  }
  { // R
    const t = await open(w, h, true)
    await t.save(); await t.page.waitForTimeout(1500)
    const txt = await t.text()
    say(w, 'R another refusal stays red, no panel', txt.includes('matches more than one sign-in') && !txt.includes('already has a sign-in'), `red=${txt.includes('matches more than one')}`)
    await t.ctx.close()
  }
}
await browser.close()
console.log(bad ? `${bad} FAIL` : 'ALL PASS')
process.exit(bad ? 1 : 0)
