// net-banner.mjs : the collector form says so when the signal drops while the page is open (Fred, 2026-11-04). Writes nothing: the server is stubbed.
//   node scripts/intake-collector/tests/net-banner.mjs [htmlPath|--live]     (default: the built intake.html)
// Control: give it a build from before the banner (git show 101e348a:scripts/intake-collector/intake.html) and the banner checks must FAIL.
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const SRC = process.argv[2] || new URL('../intake.html', import.meta.url)
const LIVE = SRC === '--live'
const html = LIVE ? null : fs.readFileSync(SRC, 'utf8')
const LOAD = JSON.parse(fs.readFileSync(new URL('./parity/load.json', import.meta.url), 'utf8')); delete LOAD.maps_key
const PAGE = 'https://planner.unclogme.app/intake.html', WORDS = 'No signal right now'
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 220)}`) }
const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' }
const b = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
for (const [name, w, h, touch] of [['phone360', 360, 740, true], ['phone390', 390, 844, true], ['laptop1280', 1280, 900, false]]) {
  const ctx = await b.newContext({ viewport: { width: w, height: h }, isMobile: touch, hasTouch: touch })
  if (!LIVE) await ctx.route(PAGE, (r) => r.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: html }))
  let up = true
  await ctx.route('**/functions/v1/intake-submit', (r) => { if (r.request().method() !== 'POST') return r.fulfill({ status: 204, headers: cors }); return up ? r.fulfill({ status: 200, contentType: 'application/json', headers: cors, body: JSON.stringify(LOAD) }) : r.abort() })
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', (e) => errs.push(String(e)))
  await p.goto(PAGE + '#code=NETTEST' + name); await p.waitForFunction(() => document.querySelectorAll('.q').length > 0); await p.waitForTimeout(300)
  const seen = () => p.evaluate((W) => { const v = [...document.querySelectorAll('.off')].filter((e) => e.textContent.includes(W) && e.getBoundingClientRect().height > 0); const r = v[0]?.getBoundingClientRect(); return { n: v.length, inView: !!r && r.top >= 0 && r.bottom <= innerHeight, text: v[0]?.textContent, fh: getComputedStyle(document.documentElement).getPropertyValue('--fh'), status: v[0]?.getAttribute('role'), over: document.documentElement.scrollWidth > innerWidth } }, WORDS)
  ok((await seen()).n === 0, name + ' online: no banner')
  const h0 = await p.evaluate(() => document.getElementById('foot').offsetHeight)
  await p.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight / 2)); await p.waitForTimeout(150)
  await ctx.setOffline(true); await p.waitForTimeout(500)
  let s = await seen()
  ok(s.n === 1 && s.inView, name + ' signal drops mid-form: one banner, on screen wherever the page is scrolled', s)
  ok(s.status === 'status', name + ' the banner is announced')
  ok(/Keep this page open/.test(s.text || ''), name + ' the banner says to keep the page open')
  ok(!s.over, name + ' no sideways scroll')
  ok(parseInt(s.fh) === await p.evaluate(() => document.getElementById('foot').offsetHeight) && parseInt(s.fh) > h0, name + ' the page knows the taller bar', { fh: s.fh, h0 })
  // an answer redraws the list; the banner stays
  await p.locator('.q .opt, .q button').first().click().catch(() => {}); await p.waitForTimeout(350)
  ok((await seen()).n === 1, name + ' still there after an answer')
  // Submit with no signal: its own message and the banner, not one over the other
  await p.fill('#who', 'Net test'); await p.click('#send'); await p.waitForTimeout(500)
  const any = p.getByRole('button', { name: 'Submit anyway' }); if (await any.isVisible().catch(() => false)) { up = false; await any.click(); await p.waitForTimeout(900) }
  ok(/No connection/.test(await p.textContent('#fmsg')) && (await seen()).n === 1, name + ' Submit: says No connection, banner kept')
  const bar = await p.evaluate(() => { const f = document.getElementById('foot').getBoundingClientRect(); return { fits: f.height < innerHeight * 0.5, h: Math.round(f.height) } }); ok(bar.fits, name + ' the bar leaves room to answer', bar)
  await p.screenshot({ path: process.env.SHOTS ? `${process.env.SHOTS}/${name}_nosignal.png` : `net_${name}.png` })
  up = true; await ctx.setOffline(false); await p.waitForTimeout(500)
  ok((await seen()).n === 0, name + ' signal back: banner gone')
  ok(errs.length === 0, name + ' no page errors', errs)
  // a reload that cannot reach the server but has the page: the old top banner, once
  up = false; await p.reload(); await p.waitForFunction(() => document.querySelectorAll('.q').length > 0); await p.waitForTimeout(300)
  ok((await seen()).n === 1, name + ' server unreachable on load: one banner')
  await ctx.close()
}
await b.close()
console.log(`${pass} passed, ${fail} failed`); if (fail) process.exitCode = 1
