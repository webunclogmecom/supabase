// option-scroll.mjs : tapping an answer on the collector form keeps the page where it is (Fred, 2026-10-01: "if we're on a
// phone and select an option for those kind of questions, it will scroll the page all the way up ... we don't want that").
// Local only, on the parity harness (fake intake-submit, Google Maps stubbed, nothing reaches Google or the database).
// It never submits.
//   node scripts/intake-collector/tests/option-scroll.mjs [outdir]
//   INTAKE_HTML=<file>  serve another build (the control: the build before the fix must FAIL)
import fs from 'node:fs'
import { pathToFileURL } from 'node:url'
const { setup, open, LOAD, sleep } = await import(process.env.PARITY_H || './parity/h.mjs')
const out = process.argv[2] || './option_scroll_shots'; fs.mkdirSync(out, { recursive: true })
const FILE = pathToFileURL(process.env.INTAKE_HTML || new URL('../intake.html', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1')).href
const REAL = !!process.env.REAL_MAP
let KEY = 'STUB-NOT-A-KEY'
if (REAL) { // the Planner's own browser key, from its public bundle (as address-dropdown.mjs does); never printed
  const H = 'https://planner.unclogme.app', seen = new Set(); KEY = null
  const walk = async (n) => { if (KEY || seen.has(n)) return; seen.add(n); const s = await (await fetch(H + '/' + n)).text(); const m = s.match(/AIza[0-9A-Za-z_-]{35}/); if (m) { KEY = m[0]; return } for (const x of s.matchAll(/["'`]\.?\/?((?:assets\/)?[A-Za-z0-9_.-]+\.js)["'`]/g)) await walk(x[1].startsWith('assets/') ? x[1] : 'assets/' + x[1]) }
  const html0 = await (await fetch(H + '/')).text()
  for (const n of new Set([...html0.matchAll(/assets\/[A-Za-z0-9_.-]+\.js/g)].map((m) => m[0]))) await walk(n)
  if (!KEY) throw new Error('no key in the Planner bundle')
}
const STUB = `(function(){function F(){} F.prototype.addListener=function(){};F.prototype.panTo=function(){};F.prototype.setZoom=function(){};F.prototype.getZoom=function(){return 19};
function K(){} K.prototype.addListener=function(){};K.prototype.setPosition=function(){};K.prototype.setMap=function(){};
window.google={maps:{Map:F,Marker:K,Size:function(){},Point:function(){},importLibrary:function(){return Promise.resolve({})}}};
setTimeout(function(){window.gmReady&&window.gmReady()},0)})();`
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v)}`) }
// [question key, option value]: the three Fred named, plus a Yes/No that shows a follow-up (the list grows under the tap)
const TAPS = [['access_entry.gate', 'yes'], ['access_entry.equipment_where', null], ['access_entry.access_point', null], ['access_entry.alarm', 'no']]
for (const [name, w, h, touch] of [['phone360', 360, 740, true], ['phone390', 390, 844, true], ['desktop1280', 1280, 900, false]]) {
  const { browser, context, page: p } = await setup({ file: FILE, mobile: touch, load: { ...LOAD, maps_key: KEY, property: { ...LOAD.property, lat: 25.8, lng: -80.2 } }, ctx: { viewport: { width: w, height: h } } })
  if (REAL) await context.route(/https:\/\/[^/]*(googleapis|gstatic|google)\.com\//, (r) => /places\.googleapis\.com/.test(r.request().url()) ? r.abort() : r.continue())
  else await context.route('https://maps.googleapis.com/**', (x) => x.fulfill({ status: 200, contentType: 'text/javascript', body: STUB }))
  await open(p); await p.waitForSelector('[data-q="access_entry.gate"]', { timeout: 20000 }); await sleep(500)
  if (REAL) {
    await p.waitForFunction(() => { const m = document.querySelector('.q .map:not(.wait)'); return m && [...m.querySelectorAll('img')].filter((i) => /googleapis|gstatic/.test(i.src) && i.complete && i.naturalWidth > 0).length >= 4 }, null, { timeout: 25000 }).catch(() => {})
    ok(await p.evaluate(() => [...document.querySelectorAll('.q .map img')].filter((i) => /googleapis|gstatic/.test(i.src) && i.complete && i.naturalWidth > 0).length >= 4), `${name}: control: the real Google map drew its tiles`)
  }
  for (const [k, v] of TAPS) {
    const sel = v ? `[data-q="${k}"] [data-f="${k}=${v}"]` : `[data-q="${k}"] button.opt`
    const b = p.locator(sel).first()
    await b.evaluate((e) => e.scrollIntoView({ block: 'center' })); await sleep(250)
    const before = await p.evaluate(() => scrollY)
    const top0 = await b.evaluate((e) => Math.round(e.getBoundingClientRect().top))
    if (touch) await b.tap(); else await b.click()
    await sleep(700)
    const after = await p.evaluate(() => scrollY)
    const pressed = await p.locator(sel).first().getAttribute('aria-pressed')
    const top1 = await p.locator(sel).first().evaluate((e) => Math.round(e.getBoundingClientRect().top))
    ok(pressed === 'true', `${name}: tapping ${k} selects it`, { pressed })
    ok(before > 200 && Math.abs(after - before) <= 2 && Math.abs(top1 - top0) <= 2, `${name}: tapping ${k} keeps the page where it was`, { before, after, top0, top1 })
  }
  await p.screenshot({ path: `${out}/${name}.png` })
  await browser.close()
}
// The Safari model (every iPhone): a tapped button never takes the focus, so a text box focused earlier keeps it, and Safari
// scrolls to a text box when it is focused again. Modelled in Chrome: mousedown on a button is cancelled (no focus moves) and
// focusing an input or textarea scrolls it to the middle. The build before the fix jumps to that box on every tap.
const SAFARI = `document.addEventListener('mousedown',function(e){ if(e.target.closest&&e.target.closest('button')) e.preventDefault() },true);
(function(){var f=HTMLElement.prototype.focus;HTMLElement.prototype.focus=function(o){f.call(this,o);if(/^(INPUT|TEXTAREA)$/.test(this.tagName))this.scrollIntoView({block:'center'})}})();`
for (const [name, w, h] of [['safari360', 360, 740], ['safari390', 390, 844]]) {
  const { browser, context, page: p } = await setup({ file: FILE, mobile: true, load: { ...LOAD, maps_key: KEY, property: { ...LOAD.property, lat: 25.8, lng: -80.2 } }, ctx: { viewport: { width: w, height: h } } })
  if (REAL) await context.route(/https:\/\/[^/]*(googleapis|gstatic|google)\.com\//, (r) => /places\.googleapis\.com/.test(r.request().url()) ? r.abort() : r.continue())
  else await context.route('https://maps.googleapis.com/**', (x) => x.fulfill({ status: 200, contentType: 'text/javascript', body: STUB }))
  await context.addInitScript(SAFARI)
  await open(p); await p.waitForSelector('[data-f="site_map.truck_parking:addr"]', { timeout: 20000 }); await sleep(700)
  // the collector taps into the prefilled address box at the top, then scrolls down the form (the box keeps the focus)
  const addr = p.locator('[data-f="site_map.truck_parking:addr"]'); await addr.tap(); await p.keyboard.press('Escape'); await sleep(200)
  ok(await addr.evaluate((e) => document.activeElement === e), `${name}: control: the address box has the focus (the model holds it)`)
  for (const [k, v] of TAPS) {
    const sel = v ? `[data-q="${k}"] [data-f="${k}=${v}"]` : `[data-q="${k}"] button.opt`
    const b = p.locator(sel).first()
    await b.evaluate((e) => e.scrollIntoView({ block: 'center' })); await sleep(250)
    const before = await p.evaluate(() => scrollY)
    await b.tap(); await sleep(700)
    const after = await p.evaluate(() => scrollY)
    const pressed = await p.locator(sel).first().getAttribute('aria-pressed')
    ok(pressed === 'true', `${name}: tapping ${k} selects it`, { pressed })
    ok(before > 200 && Math.abs(after - before) <= 2, `${name}: tapping ${k} keeps the page where it was (Safari model)`, { before, after })
    const foc = await p.evaluate(() => { const e = document.activeElement; return e && e.getAttribute('data-f') })
    ok(foc === (await p.locator(sel).first().getAttribute('data-f')), `${name}: tapping ${k} leaves the focus on the tapped answer, not the address box`, { focused: foc })
  }
  // a typed answer still keeps its caret after a rebuild (render() gives the focus back to a text box the collector is typing in)
  const gc = p.locator('[data-f="access_entry.gate_code"]'); await gc.evaluate((e) => e.scrollIntoView({ block: 'center' })); await gc.tap(); await gc.fill('12'); await p.keyboard.type('34')
  const yes = await p.evaluate(() => { const e = document.activeElement; return e && e.getAttribute('data-f') })
  ok(yes === 'access_entry.gate_code', `${name}: typing in a text box keeps its focus`, { focused: yes })
  await p.screenshot({ path: `${out}/${name}.png` })
  await browser.close()
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0)
