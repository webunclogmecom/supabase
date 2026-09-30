// address-prefill.mjs : the address box above each pin map on the collector form starts with the property's address
// (Fred, 2026-09-30: "we can have prefilled the address where all the site maps are in the intake form").
// Local only, on the parity harness: the built form is served at its real URL, intake-submit is faked from
// parity/load.json (plus a maps_key and the property's lat/lng), Google Maps and Places are STUBS, so nothing reaches
// Google or the database. It never submits.
//   node scripts/intake-collector/tests/address-prefill.mjs [outdir]
//   INTAKE_HTML=<file>  serve another build (the control: the build before the prefill must FAIL the prefill checks)
import fs from 'node:fs'
import { pathToFileURL } from 'node:url'
const { setup, open, LOAD, sleep } = await import(process.env.PARITY_H || './parity/h.mjs')
const out = process.argv[2] || './prefill_shots'; fs.mkdirSync(out, { recursive: true })
const FILE = pathToFileURL(process.env.INTAKE_HTML || new URL('../intake.html', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1')).href
const HOME = { lat: 25.8093, lng: -80.2083 }, PIN = { lat: 25.8111, lng: -80.2222 }
const TRUCK = 'site_map.truck_parking', GT = 'site_map.gt_location', KEYD = 'intake-draft-TESTTOKEN123'
const EXP = `${LOAD.property.address}, ${LOAD.property.city}`          // '650 Northwest 33rd Street, Miami'
const mk = (prop) => ({ ...LOAD, maps_key: 'STUB-NOT-A-KEY', property: { ...LOAD.property, lat: HOME.lat, lng: HOME.lng, ...prop } })
const SUGG = [['650 Northwest 33rd Street', 'Miami, FL, USA'], ['650 NW 33rd Ave', 'Miami, FL, USA'], ['650 NW 33rd Ct', 'Miami, FL, USA']]
  .map(([m, s], i) => ({ m, s, lat: 25.8 + i * 0.01, lng: -80.2 - i * 0.01 }))
// Places stub: every search's text goes to window.__inputs; Place Details answers at once with the row's own spot.
const PLACES = `{AutocompleteSessionToken:function(){},AutocompleteSuggestion:{fetchAutocompleteSuggestions:function(req){window.__inputs.push(req.input);
  return Promise.resolve({suggestions:window.__S.map(function(s){return {placePrediction:{mainText:{text:s.m},secondaryText:{text:s.s},text:{text:s.m+', '+s.s},
  toPlace:function(){var p={fetchFields:function(){p.location={lat:function(){return s.lat},lng:function(){return s.lng}};p.formattedAddress=s.m+', '+s.s;return Promise.resolve()}};return p}}}})})}}}`
const INIT = `window.__S=${JSON.stringify(SUGG)};window.__inputs=[];window.__maps=[];window.__pans=[];window.__zooms=[];`
// Maps stub: each map's opening center and zoom go to window.__maps, every panTo and setZoom after that is recorded.
const STUB = `(function(){
function F(el,o){window.__maps.push({lat:o.center.lat,lng:o.center.lng,z:o.zoom})} F.prototype.addListener=function(){};F.prototype.panTo=function(ll){window.__pans.push(ll)};F.prototype.setZoom=function(z){window.__zooms.push(z)};F.prototype.getZoom=function(){return 19};
function K(){} K.prototype.addListener=function(){};K.prototype.setPosition=function(){};K.prototype.setMap=function(){};
window.google={maps:{Map:F,Marker:K,Size:function(){},Point:function(){},importLibrary:function(){return Promise.resolve(${PLACES})}}};
setTimeout(function(){window.gmReady&&window.gmReady()},0)})();`

let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 360)}`) }
const near = (a, s) => !!a && Math.abs(a.lat - s.lat) < 1e-6 && Math.abs(a.lng - s.lng) < 1e-6
const go = async (o) => {
  const r = await setup({ file: FILE, ...o })
  await r.context.addInitScript(INIT)
  await r.context.route('https://maps.googleapis.com/**', (x) => x.fulfill({ status: 200, contentType: 'text/javascript', body: STUB }))
  return r
}
const ready = async (p) => { await p.waitForSelector(`[data-f="${TRUCK}:addr"]`, { timeout: 20000 }); await sleep(700) }   // 700 ms: past the 350 ms search delay
const box = (p, k) => p.locator(`[data-f="${k}:addr"]`)
const searched = (p, k) => box(p, k).inputValue().then((t) => p.waitForFunction(([k, t]) => window.__inputs[window.__inputs.length - 1] === t && document.querySelectorAll(`[data-q="${k}"] .asug`).length > 0, [k, t.trim()], { timeout: 4000 }).catch(() => {}))
const st = (p, k) => p.evaluate(([k, kd]) => {
  const q = document.querySelector(`[data-q="${k}"]`), i = q && q.querySelector('.asr input')
  if (!i) return null
  return { v: i.value, ph: i.placeholder, exp: i.getAttribute('aria-expanded'), rows: q.querySelectorAll('.asug').length, hint: (q.querySelector('.ahint') || {}).textContent,
    inputs: window.__inputs.slice(), maps: window.__maps.slice(), pans: window.__pans.length, zooms: window.__zooms.length,
    draft: JSON.parse(localStorage.getItem(kd) || '{}'), pin: (JSON.parse(localStorage.getItem(kd) || '{}'))[k] || null, off: !!document.querySelector('.off'), overflowX: document.documentElement.scrollWidth > innerWidth }
}, [k, KEYD])

for (const [name, w, h, touch] of [['phone360', 360, 740, true], ['desktop1280', 1280, 900, false]]) {
  const { browser, page: p, S } = await go({ mobile: touch, load: mk({}), ctx: { viewport: { width: w, height: h }, deviceScaleFactor: touch ? 2 : 1 } })
  await open(p); await ready(p)
  const t0 = await st(p, TRUCK)
  ok(t0 && t0.v === EXP, `${name}: the Truck parking spot box starts with the property's address and city`, t0 && t0.v)
  ok(t0 && t0.inputs.length === 0 && t0.exp === 'false' && t0.rows === 0 && t0.hint === '', `${name}: on load nothing is searched and no list is open`, t0 && { inputs: t0.inputs, exp: t0.exp, rows: t0.rows, hint: t0.hint })
  ok(t0 && t0.maps.length === 1 && near(t0.maps[0], HOME) && t0.maps[0].z === 19 && t0.pans === 0 && t0.zooms === 0, `${name}: the map opens on the property at zoom 19 and the prefill does not move it`, t0 && { maps: t0.maps, pans: t0.pans, zooms: t0.zooms })
  await box(p, TRUCK).evaluate((e) => e.closest('.q').scrollIntoView({ block: 'start' })); await sleep(150)
  await p.screenshot({ path: `${out}/${name}_prefill.png` })
  // the grease trap map appears once there is a trap: its box starts the same way, still with no search
  const sys = p.locator('[data-q="grease_trap.systems_count"] input'); await sys.fill('1'); await sys.dispatchEvent('change'); await sleep(900)
  const g0 = await st(p, GT)
  ok(g0 && g0.v === EXP && g0.rows === 0 && g0.inputs.length === 0, `${name}: the Grease trap location box starts with the same text, still with no search`, g0 && { v: g0.v, rows: g0.rows, inputs: g0.inputs })
  // typing at the end of the prefilled text searches the whole text and opens the list
  await box(p, TRUCK).click(); await p.keyboard.press('End'); await p.keyboard.type(' FL', { delay: 30 }); await searched(p, TRUCK)
  const t1 = await st(p, TRUCK)
  ok(t1.v === EXP + ' FL' && t1.rows === 3 && t1.exp === 'true' && t1.inputs[t1.inputs.length - 1] === t1.v, `${name}: typing at the end of the prefilled text searches the whole text and opens the list`, { v: t1.v, rows: t1.rows, exp: t1.exp, last: t1.inputs.slice(-1) })
  await box(p, TRUCK).press('Escape'); await sleep(150)
  // what the collector typed survives a render (another answer rebuilds the cards; the prefill is never put back)
  const v0 = await box(p, TRUCK).inputValue()
  await p.locator('[data-f="access_entry.gate=yes"]').first().click(); await sleep(500)
  const pressed = await p.locator('[data-f="access_entry.gate=yes"]').first().getAttribute('aria-pressed')
  const v1 = await box(p, TRUCK).inputValue()
  ok(pressed === 'true' && v0.length > 0 && v1 === v0, `${name}: a render keeps the text the collector typed (the prefill is never put back)`, { pressed, v0, v1 })
  // the box text is not an answer: it is in the draft neither on load nor after an answer is saved (rule 6)
  const dr = (await st(p, TRUCK)).draft
  ok(!Object.values(t0.draft).includes(EXP) && !Object.values(dr).includes(v1) && !Object.values(dr).includes(EXP), `${name}: the box text is never saved in the draft (it is not an answer)`, { onLoad: Object.keys(t0.draft), afterAnswer: Object.keys(dr) })
  // guard: clearing the box and typing an address works as before
  await box(p, TRUCK).fill(''); await box(p, TRUCK).click(); await p.keyboard.type('650 NW 33rd St', { delay: 20 }); await searched(p, TRUCK)
  const t2 = await st(p, TRUCK)
  ok(t2.rows === 3 && t2.exp === 'true' && t2.inputs[t2.inputs.length - 1] === '650 NW 33rd St', `${name}: clearing the box and typing an address still opens the list`, { rows: t2.rows, last: t2.inputs.slice(-1) })
  await box(p, TRUCK).press('Escape'); await sleep(150)
  // a tap on the untouched prefill searches nothing and opens nothing (no paid call on a tap)
  const n0 = (await st(p, GT)).inputs.length
  await box(p, GT).click(); await sleep(700)
  const gf = await st(p, GT)
  ok(gf.inputs.length === n0 && gf.exp === 'false' && gf.rows === 0 && gf.v === EXP, `${name}: a tap on the untouched prefill searches nothing and opens no list`, { v: gf.v, searches: gf.inputs.length - n0, exp: gf.exp, rows: gf.rows })
  // Enter on the untouched prefill with NO pin yet (the grease trap box) searches that text and puts the pin on the first answer
  await box(p, GT).press('Enter'); await sleep(700)
  const g1 = await st(p, GT)
  ok(g1.inputs.includes(EXP) && near(g1.pin, SUGG[0]) && /Pin placed at that address/.test(g1.hint) && g1.v === `${SUGG[0].m}, ${SUGG[0].s}`, `${name}: Enter on the untouched prefill, no pin yet, searches that text and puts the pin on the first answer`, { last: g1.inputs.slice(-1), pin: g1.pin, hint: g1.hint, v: g1.v })
  ok(!(await st(p, TRUCK)).overflowX, `${name}: no sideways scroll`)
  ok(S.ops.every((o) => o === 'load') && S.errors.length === 0, `${name}: only the load call reached the (fake) backend, no page error`, { ops: S.ops, errors: S.errors.slice(0, 3) })
  await browser.close()
}

// the property's own address decides the text (phone390, one page each)
for (const [label, prop, want] of [
  ['no address: the box stays empty and shows its placeholder', { address: null }, ''],
  ['an address that already holds the city is used as it is', { address: '650 Northwest 33rd Street, MIAMI, FL 33127' }, '650 Northwest 33rd Street, MIAMI, FL 33127'],
  ['no city: the address alone', { city: null }, '650 Northwest 33rd Street'],
  ['the city inside a street name still gets ", city" (N Miami Ave in Miami)', { address: '1200 North Miami Avenue' }, '1200 North Miami Avenue, Miami'],
]) {
  const { browser, page: p, S } = await go({ mobile: true, load: mk(prop) })
  await open(p); await ready(p)
  const t = await st(p, TRUCK)
  ok(t && t.v === want && t.ph === 'Type an address to move the map' && S.errors.length === 0, `phone390: ${label}`, t && { v: t.v, ph: t.ph, errors: S.errors.slice(0, 2) })
  await browser.close()
}

{ // a draft pin on the phone: the map opens on the pin, the box still starts with the address, Enter on it leaves the pin;
  // a reload that cannot reach intake-submit keeps both; Enter on text the collector typed still moves the pin
  const { browser, context, page: p, S } = await go({ mobile: true, load: mk({}) })
  await context.addInitScript(([k, pin, t]) => { if (!localStorage.getItem(k)) localStorage.setItem(k, JSON.stringify({ [t]: pin })) }, [KEYD, PIN, TRUCK])
  await open(p); await ready(p)
  const d0 = await st(p, TRUCK)
  ok(d0 && d0.maps.length === 1 && near(d0.maps[0], PIN) && d0.maps[0].z === 20 && d0.pans === 0 && near(d0.pin, PIN), 'phone390: with a draft pin the map opens on the pin at zoom 20 and the pin stays', d0 && { maps: d0.maps, pans: d0.pans, pin: d0.pin })
  ok(d0 && d0.v === EXP && d0.inputs.length === 0, 'phone390: with a draft pin the box still starts with the address, no search', d0 && { v: d0.v, inputs: d0.inputs })
  await box(p, TRUCK).click(); await box(p, TRUCK).press('Enter'); await sleep(700)
  const d2 = await st(p, TRUCK)
  ok(d2 && d2.v === EXP && d2.inputs.length === 0 && d2.pans === 0 && near(d2.pin, PIN), 'phone390: with a pin already placed, Enter on the untouched prefill does nothing (nothing searched, the pin stays)', d2 && { v: d2.v, inputs: d2.inputs, pans: d2.pans, pin: d2.pin })
  await box(p, TRUCK).fill('typed before the reload'); await sleep(500)
  S.load = 'abort'   // intake-submit unreachable: the form comes from the copy on the phone (Maps stays stubbed; truly offline there is no map)
  await p.reload(); await ready(p)
  const d1 = await st(p, TRUCK)
  ok(d1 && d1.off && d1.v === EXP && near(d1.maps[0], PIN) && near(d1.pin, PIN), 'phone390: a reload that cannot reach intake-submit starts the box with the address again (typed text is not kept, the pin is)', d1 && { off: d1.off, v: d1.v, maps: d1.maps, pin: d1.pin })
  await box(p, TRUCK).fill('650 NW 33rd St'); await box(p, TRUCK).press('Enter'); await sleep(700)
  const d3 = await st(p, TRUCK)
  ok(d3 && d3.inputs.includes('650 NW 33rd St') && near(d3.pin, SUGG[0]), 'phone390: with a pin placed, Enter on text the collector typed still moves the pin (as before)', d3 && { last: d3.inputs.slice(-1), pin: d3.pin })
  await browser.close()
}
console.log(`\n${pass} passed, ${fail} failed  [${process.env.INTAKE_HTML ? 'INTAKE_HTML=' + process.env.INTAKE_HTML.split(/[\\/]/).pop() : 'intake.html'}]`)
if (fail) process.exitCode = 1
