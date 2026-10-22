// map-row.mjs : the collector form's pin card (Fred, 2026-10-21, Trello 1Mej1zDX): "Use my location" sits next to the
// address box, and the instruction line sits ABOVE the box, in red until a pin is placed. Below 480px the button shows
// only its pin icon (Fred picked option A); its words stay its accessible name. A card with no map keeps the old order.
// Local only, on the parity harness: the built form at its real URL, intake-submit faked from parity/load.json (plus a
// maps_key), Google Maps STUBBED, geolocation faked. Nothing reaches Google or the database; it never submits.
//   node scripts/intake-collector/tests/map-row.mjs [outdir]
//   INTAKE_HTML=<file>  serve another build (the control: the build before this change must FAIL the row checks)
import fs from 'node:fs'
import { pathToFileURL } from 'node:url'
const { setup, open, LOAD, sleep } = await import(process.env.PARITY_H || './parity/h.mjs')
const out = process.argv[2] || './map_row_shots'; fs.mkdirSync(out, { recursive: true })
const FILE = pathToFileURL(process.env.INTAKE_HTML || new URL('../intake.html', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1')).href
const HOME = { lat: 25.8093, lng: -80.2083 }, TRUCK = 'site_map.truck_parking'
const STUB = `(function(){function F(){} F.prototype.addListener=function(){};F.prototype.panTo=function(){};F.prototype.setZoom=function(){};F.prototype.getZoom=function(){return 19};
function K(){} K.prototype.addListener=function(){};K.prototype.setPosition=function(){};K.prototype.setMap=function(){};
window.google={maps:{Map:F,Marker:K,Size:function(){},Point:function(){},importLibrary:function(){return new Promise(function(){})}}};
setTimeout(function(){window.gmReady&&window.gmReady()},0)})();`
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 300)}`) }
const card = (p, withMap) => p.evaluate(([k, withMap]) => {
  const q = document.querySelector(`[data-q="${k}"]`), r = (e) => e && e.getBoundingClientRect()
  const inp = q.querySelector('.asr input'), btn = [...q.querySelectorAll('button')].find((b) => b.getAttribute('data-f') === k + ':gps')
  const pin = q.querySelector('.pin'), map = q.querySelector('.map')
  const bi = r(inp), bb = r(btn), bp = r(pin), bm = r(map), row = r(q.querySelector('.arow'))
  return { withMap, hasRow: !!q.querySelector('.arow'), btnInSlot: !!(btn && btn.closest('.aslot')),
    pinAboveBox: !!(bp && bi && bp.bottom <= bi.top + 1), pinAboveMap: !!(bp && bm && bp.bottom <= bm.top + 1),
    sameLine: !!(bi && bb && bb.top < bi.bottom && bb.bottom > bi.top), btnRight: !!(bi && bb && bb.left >= bi.right),
    btnW: bb && Math.round(bb.width), btnH: bb && Math.round(bb.height), inpH: bi && Math.round(bi.height), inpShare: bi && row ? Math.round(100 * bi.width / row.width) : null,
    textShown: !!(btn && btn.querySelector('span') && btn.querySelector('span').getBoundingClientRect().width > 2),
    name: btn && (btn.textContent || '').trim(), pinText: pin && pin.textContent, pinColor: pin && getComputedStyle(pin).color, pinCls: pin && pin.className,
    order: [...q.children].map((c) => c.tagName === 'BUTTON' ? 'button' : (c.className || c.tagName).split(' ')[0]),
    overflowX: document.documentElement.scrollWidth > innerWidth }
}, [TRUCK, withMap])

for (const [name, w, h, touch] of [['phone360', 360, 740, true], ['phone390', 390, 844, true], ['phone479', 479, 900, true], ['tablet768', 768, 1024, true], ['desktop1280', 1280, 900, false]]) {
  const r = await setup({ file: FILE, mobile: touch, load: { ...LOAD, maps_key: 'STUB-NOT-A-KEY', property: { ...LOAD.property, lat: HOME.lat, lng: HOME.lng } },
    ctx: { viewport: { width: w, height: h }, deviceScaleFactor: touch ? 2 : 1, geolocation: { latitude: 25.80941, longitude: -80.20511, accuracy: 9 }, permissions: ['geolocation'] } })
  await r.context.route('https://maps.googleapis.com/**', (x) => x.fulfill({ status: 200, contentType: 'text/javascript', body: STUB }))
  const p = r.page
  await open(p); await p.waitForSelector(`[data-f="${TRUCK}:addr"]`, { timeout: 20000 }); await sleep(400)
  const a = await card(p, true)
  ok(a.hasRow && a.btnInSlot, `${name}: the button sits in the row of the address box`, { hasRow: a.hasRow, btnInSlot: a.btnInSlot })
  ok(a.sameLine && a.btnRight, `${name}: the button is on the same line, right of the box`, { sameLine: a.sameLine, btnRight: a.btnRight })
  ok(a.pinAboveBox && a.pinAboveMap && a.order[1] === 'pin', `${name}: the instruction is above the box and the map`, a.order)
  ok(/Tap the map where it is/.test(a.pinText) && /\bask\b/.test(a.pinCls) && a.pinColor === 'rgb(185, 28, 28)', `${name}: the instruction is red (#b91c1c) before a pin is placed`, { cls: a.pinCls, color: a.pinColor })
  ok(a.name === 'Use my location' || /Use my location/.test(await p.locator(`[data-f="${TRUCK}:gps"]`).evaluate((b) => b.innerText + '|' + b.textContent)), `${name}: its accessible name is "Use my location"`, a.name)
  const role = await p.getByRole('button', { name: 'Use my location' }).count()
  ok(role >= 1, `${name}: getByRole finds the button by its name`, role)
  if (w < 480) ok(!a.textShown && a.btnW === a.btnH && a.btnH >= 44 && a.inpShare >= 70, `${name}: under 480px only the pin icon shows, a square of the box's height, the box keeps most of the row`, { textShown: a.textShown, w: a.btnW, h: a.btnH, inpShare: a.inpShare })
  else ok(a.textShown && a.btnH >= (touch ? 44 : 36), `${name}: from 480px the words show`, { textShown: a.textShown, h: a.btnH })
  ok(a.btnH === a.inpH, `${name}: the button is as tall as the box`, { btn: a.btnH, inp: a.inpH })
  ok(!a.overflowX, `${name}: no sideways scroll`)
  await p.locator(`[data-q="${TRUCK}"]`).evaluate((e) => e.scrollIntoView({ block: 'start' })); await sleep(150)
  await p.screenshot({ path: `${out}/${name}_row.png` })
  // Use my location still pins (faked GPS, within 15 m: it finishes at once); the line turns green "Pinned at"
  await p.getByRole('button', { name: 'Use my location' }).first().click(); await sleep(900)
  const b = await card(p, true)
  ok(/Pinned at 25\.809410, -80\.205110/.test(b.pinText) && /\bset\b/.test(b.pinCls) && !/\bask\b/.test(b.pinCls) && b.pinAboveBox, `${name}: after Use my location the line above the box reads "Pinned at" in green`, { text: b.pinText, cls: b.pinCls })
  ok(b.btnInSlot && b.sameLine && /Use my location again/.test(b.name), `${name}: the button stays beside the box ("Use my location again")`, b.name)
  // a render (another answer) keeps the layout
  await p.locator('[data-f="access_entry.gate=yes"]').first().click(); await sleep(400)
  const c = await card(p, true)
  ok(c.btnInSlot && c.sameLine && c.pinAboveBox, `${name}: a render keeps the row`)
  ok(r.S.errors.length === 0, `${name}: no page errors`, r.S.errors.slice(0, 2))
  await r.browser.close()
}
// no map (no key): the old order, the button full width under the label, the line under it, not red
{
  const r = await setup({ file: FILE, mobile: true, load: { ...LOAD, maps_key: null }, ctx: { viewport: { width: 390, height: 844 } } })
  const p = r.page; await open(p); await p.waitForSelector(`[data-q="${TRUCK}"]`, { timeout: 20000 }); await sleep(300)
  const d = await card(p, false)
  ok(!d.hasRow && d.order.join(',') === 'LABEL,button,pin,gst' && /Stand next to it/.test(d.pinText) && d.pinColor !== 'rgb(185, 28, 28)' && d.textShown, 'no map: the card is as before (button, then the line, not red, words shown)', { order: d.order, color: d.pinColor })
  await r.browser.close()
}
console.log(`${pass} passed, ${fail} failed  [${(process.env.INTAKE_HTML || 'intake.html').split(/[\\/]/).pop()}]`)
process.exit(fail ? 1 : 0)
