// node shots2.mjs <outdir> [htmlPath|--live] : viewport screenshots of the collector page in real states, per width.
// Writes nothing to the server (no submit, no upload). Never prints the token.
import fs from 'node:fs'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const [out, src = fileURLToPath(new URL('../intake.html', import.meta.url))] = process.argv.slice(2)
fs.mkdirSync(out, { recursive: true })
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const r = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: "select token from public.property_intakes where requested_by like '[TEST] collector page check%' and submitted_at is null and cancelled_at is null and expires_at > now() order by id desc limit 1" }) })
const [{ token }] = await r.json()
const PAGE = 'https://planner.unclogme.app/intake.html'
const b = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
// Touch contexts keep the phone scale (44px targets, 16px inputs); a mouse from 600px up gets the PC scale
// (the LAST @media block in form-page.ts, 2026-09-25), so it is checked with its own numbers, not the phone ones.
for (const [name, w, h, dpr, touch] of [['phone360', 360, 740, 2, true], ['phone390', 390, 844, 2, true], ['tablet768', 768, 1024, 1, true], ['laptop768', 768, 1024, 1, false], ['desktop1280', 1280, 900, 1, false]]) {
  const ctx = await b.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: dpr, isMobile: touch && w < 700, hasTouch: touch, geolocation: { latitude: 25.80941, longitude: -80.20511, accuracy: 9 }, permissions: ['geolocation'] })
  const p = await ctx.newPage()
  if (src !== '--live') { const html = fs.readFileSync(src, 'utf8'); await p.route(PAGE, (rt) => rt.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: html })) }
  await p.goto(PAGE + '#code=' + token)
  await p.waitForFunction(() => document.getElementById('sub').textContent !== 'Loading...', null, { timeout: 15000 })
  await p.waitForTimeout(400)
  const shot = async (tag, sel) => { if (sel) await p.locator(sel).first().evaluate((e) => e.scrollIntoView({ block: 'start' })); await p.evaluate(() => window.scrollBy(0, -12)); await p.waitForTimeout(150); await p.screenshot({ path: `${out}/${name}_${tag}.png` }) }
  await shot('1top')
  const footBefore = await p.evaluate(() => Math.round(document.getElementById('foot').getBoundingClientRect().height))
  await p.locator('.q', { hasText: 'Truck parking spot' }).getByRole('button', { name: 'Use my location' }).click(); await p.waitForTimeout(800)
  await p.locator('.q', { hasText: 'Is there a closed gate?' }).getByRole('button', { name: 'Yes' }).click()
  await p.locator('.q', { hasText: 'Where is the equipment located?' }).getByRole('button', { name: 'Inside' }).click()
  await p.locator('.q', { hasText: 'How do we get in?' }).getByRole('button', { name: 'Lock box' }).click()
  await shot('2access', '.q:has-text("Is there a closed gate?")')
  await shot('3choices', '.q:has-text("How do we get in?")')
  for (const d of ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']) await p.locator('.q', { hasText: 'When can we come?' }).getByRole('button', { name: d, exact: true }).click()
  await p.locator('.q', { hasText: 'When can we come?' }).locator('input[aria-label="Fri closes"]').fill('02:00')
  await p.locator('.q', { hasText: 'When can we come?' }).locator('input[aria-label="Fri closes"]').dispatchEvent('change'); await p.waitForTimeout(200)
  await shot('4hours', '.q:has-text("When can we come?")')
  await p.locator('.q', { hasText: 'How many grease trap systems?' }).getByRole('button', { name: 'One more' }).click(); await p.waitForTimeout(150)
  await shot('5trap', '.q:has-text("How many grease trap systems?")')
  await p.click('#send'); await p.waitForTimeout(400)
  await shot('6noname')
  await p.fill('#who', 'Test Collector'); await p.click('#send'); await p.waitForTimeout(300)
  await p.screenshot({ path: `${out}/${name}_7confirm.png` })
  const m = await p.evaluate(() => ({ overflowX: document.documentElement.scrollWidth > innerWidth, foot: Math.round(document.getElementById('foot').getBoundingClientRect().height), small: [...document.querySelectorAll('button,input,textarea')].filter((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && r.height < 44 && e.type !== 'file' && !e.closest('.err') }).map((e) => (e.getAttribute('aria-label') || e.textContent || e.type).trim().slice(0, 20) + ':' + Math.round(e.getBoundingClientRect().height)).slice(0, 8), tinyFonts: [...document.querySelectorAll('input,textarea')].filter((e) => e.type !== 'file' && parseFloat(getComputedStyle(e).fontSize) < 16).length }))
  if (touch) console.log(name, JSON.stringify(m))
  else console.log(name, JSON.stringify({ overflowX: m.overflowX, footBefore, ...(await p.evaluate(() => {
    const px = (e) => e && Math.round(e.getBoundingClientRect().height)
    const fw = (s) => [...document.querySelectorAll(s)].map((e) => +getComputedStyle(e).fontWeight)
    return { send: px(document.getElementById('send')), maxWeight: Math.max(...fw('#send'), ...fw('.opt'), ...fw('.sech h2'), ...fw('.q>label')) }
  })) }), '(PC scale: expect footBefore 53, send 36, maxWeight <= 600)')
  await ctx.close()
}
await b.close()
