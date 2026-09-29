// address-dropdown.mjs : the collector form's address suggestions are ONE dropdown under the box (variant A, Fred
// 2026-09-29: "make it be on the same searchbar like a dropdown with the options, like a normal searchbar for addresses").
// Local only: the parity harness serves the built form at its real URL and fakes intake-submit from parity/load.json
// (plus a maps_key and the property's lat/lng); Google Maps is a STUB script and Places is a STUB that returns six fixed
// suggestions, so nothing reaches Google or the database. It never submits.
//   node scripts/intake-collector/tests/address-dropdown.mjs [outdir]
//   INTAKE_HTML=<file>  serve another build (the control: the build before the dropdown must FAIL the dropdown checks)
//   REAL_MAP=1          draw the REAL Google map (key read from the Planner's public bundle, never printed) with Places
//                       still stubbed, to check the list paints above Google's own map layers
import fs from 'node:fs'
import { pathToFileURL } from 'node:url'
const { setup, open, LOAD, sleep } = await import('./parity/h.mjs')
const out = process.argv[2] || './dropdown_shots'; fs.mkdirSync(out, { recursive: true })
const FILE = pathToFileURL(process.env.INTAKE_HTML || new URL('../intake.html', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1')).href
const REAL = !!process.env.REAL_MAP
let KEY = 'STUB-NOT-A-KEY'
if (REAL) { // the Planner's own browser key, from its public bundle (as form-map.mjs does)
  const H = 'https://planner.unclogme.app', seen = new Set(); KEY = null
  const walk = async (n) => { if (KEY || seen.has(n)) return; seen.add(n); const s = await (await fetch(H + '/' + n)).text(); const m = s.match(/AIza[0-9A-Za-z_-]{35}/); if (m) { KEY = m[0]; return } for (const x of s.matchAll(/["'`]\.?\/?((?:assets\/)?[A-Za-z0-9_.-]+\.js)["'`]/g)) await walk(x[1].startsWith('assets/') ? x[1] : 'assets/' + x[1]) }
  const html0 = await (await fetch(H + '/')).text()
  for (const n of new Set([...html0.matchAll(/assets\/[A-Za-z0-9_.-]+\.js/g)].map((m) => m[0]))) await walk(n)
  if (!KEY) throw new Error('no key in the Planner bundle')
}
const HOME = { lat: 25.8093, lng: -80.2083 }
const load = { ...LOAD, maps_key: KEY, property: { ...(LOAD.property || {}), lat: HOME.lat, lng: HOME.lng } }
// Six suggestions (the form must show at most five), each with its own spot.
const SUGG = [['650 Northwest 33rd Street', 'Miami, FL, USA'], ['650 Northwest 33rd Street', 'Oakland Park, FL, USA'], ['650 Northwest 33rd Street', 'Pompano Beach, FL, USA'],
  ['650 Northwest 33rd Street', 'Doral, FL, USA'], ['650 NW 33rd Ave', 'Miami, FL, USA'], ['650 NW 33rd Ct', 'Miami, FL, USA']].map(([m, s], i) => ({ m, s, lat: 25.8 + i * 0.01, lng: -80.2 - i * 0.01 }))
// The Places stub: counts every search in window.__places, resolves Place Details at once with the row's own spot.
const PLACES = `{AutocompleteSessionToken:function(){},AutocompleteSuggestion:{fetchAutocompleteSuggestions:function(req){window.__places++;
  return Promise.resolve({suggestions:window.__S.map(function(s){return {placePrediction:{mainText:{text:s.m},secondaryText:{text:s.s},text:{text:s.m+', '+s.s},
  toPlace:function(){var p={fetchFields:function(){var LL=window.google.maps.LatLng;p.location=LL?new LL(s.lat,s.lng):{lat:function(){return s.lat},lng:function(){return s.lng}};p.formattedAddress=s.m+', '+s.s;return Promise.resolve()}};return p}}}})})}}}`
const INIT = `window.__S=${JSON.stringify(SUGG)};window.__places=0;window.__pans=[];window.__zooms=[];`
// The Maps stub: just what mapFor() uses; panTo and setZoom are recorded. The map stays a blank grey box.
const STUB = `(function(){
function F(){} F.prototype.addListener=function(){};F.prototype.panTo=function(ll){window.__pans.push({lat:typeof ll.lat==='function'?ll.lat():ll.lat,lng:typeof ll.lng==='function'?ll.lng():ll.lng})};F.prototype.setZoom=function(z){window.__zooms.push(z)};F.prototype.getZoom=function(){return 19};
function K(){} K.prototype.addListener=function(){};K.prototype.setPosition=function(){};K.prototype.setMap=function(){};
window.google={maps:{Map:F,Marker:K,Size:function(){},Point:function(){},importLibrary:function(){return Promise.resolve(${PLACES})}}};
setTimeout(function(){window.gmReady&&window.gmReady()},0)})();`

let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 360)}`) }
const PIN = 'site_map.truck_parking', KEYD = 'intake-draft-TESTTOKEN123'
const ORT = 'rgb(255, 244, 239)', WHITE = 'rgb(255, 255, 255)'
const CONTEXTS = REAL ? [['phone390', 390, 844, true], ['desktop1280', 1280, 900, false]]
  : [['phone360', 360, 740, true], ['phone390', 390, 844, true], ['tablet768', 768, 1024, true], ['laptop768', 768, 1024, false], ['desktop1280', 1280, 900, false]]
for (const [name, w, h, touch] of CONTEXTS) {
  const pc = !touch && w >= 600            // the PC scale: a mouse at 600px and up
  const { browser, context, page: p, S } = await setup({ mobile: touch, file: FILE, load, ctx: { viewport: { width: w, height: h }, deviceScaleFactor: touch ? 2 : 1 } })
  await context.addInitScript(INIT)
  const google = [], placesNet = []
  if (REAL) {
    await context.route(/https:\/\/[^/]*(googleapis|gstatic|google)\.com\//, (r) => { const u = r.request().url(); if (/places\.googleapis\.com/.test(u)) { placesNet.push(u); return r.abort() } google.push(u); return r.continue() })
    await context.addInitScript(`(function(){var iv=setInterval(function(){var g=window.google&&window.google.maps;if(!g||!g.importLibrary||g.__stub)return;g.__stub=1;var real=g.importLibrary;g.importLibrary=function(n){return n==='places'?Promise.resolve(${PLACES}):real.apply(this,arguments)};clearInterval(iv)},5);var iv2=setInterval(function(){var M=window.google&&window.google.maps&&window.google.maps.Map;if(!M||M.__rec)return;M.__rec=1;var pt=M.prototype.panTo,sz=M.prototype.setZoom;M.prototype.panTo=function(ll){window.__pans.push({lat:typeof ll.lat==='function'?ll.lat():ll.lat,lng:typeof ll.lng==='function'?ll.lng():ll.lng});return pt.apply(this,arguments)};M.prototype.setZoom=function(z){window.__zooms.push(z);return sz.apply(this,arguments)};clearInterval(iv2)},5)})()`)
  } else {
    await context.route('https://maps.googleapis.com/**', (r) => { google.push(r.request().url()); r.fulfill({ status: 200, contentType: 'text/javascript', body: STUB }) })
  }
  await open(p)
  const card = p.locator('.q', { hasText: 'Truck parking spot' })
  await p.waitForSelector('.q .asr input', { timeout: 20000 })
  if (REAL) await p.waitForFunction(() => { const m = document.querySelector('.q .map:not(.wait)'); return m && [...m.querySelectorAll('img')].filter((i) => /googleapis|gstatic/.test(i.src) && i.complete && i.naturalWidth > 0).length >= 4 }, null, { timeout: 25000 }).catch(() => {})
  if (REAL) ok(await p.evaluate(() => [...document.querySelectorAll('.q .map img')].filter((i) => /googleapis|gstatic/.test(i.src) && i.complete && i.naturalWidth > 0).length >= 4), `${name}: control: the real Google map drew its tiles`)
  const box = card.locator('.asr input')
  const mapTop = () => card.locator('.map').evaluate((e) => e.getBoundingClientRect().top + scrollY)
  const tap = async (loc) => { const b = await loc.boundingBox(); if (touch) await p.touchscreen.tap(b.x + b.width / 2, b.y + b.height / 2); else await p.mouse.click(b.x + b.width / 2, b.y + b.height / 2) }
  const state = () => p.evaluate(() => {
    const q = [...document.querySelectorAll('.q')].find((e) => /Truck parking spot/.test(e.textContent))
    const inp = q.querySelector('.asr input'), list = q.querySelector('.alist'), rows = [...q.querySelectorAll('.asug')]
    const R = (e) => e.getBoundingClientRect().toJSON(), cs = (e) => getComputedStyle(e)
    return { inp: R(inp), list: R(list), listPos: cs(list).position, rows: rows.map((r) => ({ h: r.getBoundingClientRect().height, bg: cs(r).backgroundColor, role: r.getAttribute('role'), sel: r.getAttribute('aria-selected'), id: r.id,
        m: r.querySelector('.m') && (cs(r.querySelector('.m')).fontSize + '/' + cs(r.querySelector('.m')).fontWeight), s: r.querySelector('.s') && (cs(r.querySelector('.s')).fontSize + ' ' + cs(r.querySelector('.s')).color) })),
      role: inp.getAttribute('role'), exp: inp.getAttribute('aria-expanded'), ctl: inp.getAttribute('aria-controls'), ad: inp.getAttribute('aria-activedescendant'),
      listId: list.id, listRole: list.getAttribute('role'), rbl: cs(inp).borderBottomLeftRadius, rbr: cs(inp).borderBottomRightRadius, focused: document.activeElement === inp,
      hint: (q.querySelector('.ahint') || {}).textContent, overflowX: document.documentElement.scrollWidth > innerWidth }
  })
  const openList = async (txt = '650 NW 33rd St') => { await box.fill(''); await box.click(); await box.fill(txt); await p.waitForFunction(() => document.querySelectorAll('.q .asug').length > 0, null, { timeout: 5000 }).catch(() => {}); await sleep(150) }
  const pin = () => p.evaluate(([k, pk]) => (JSON.parse(localStorage.getItem(k) || '{}'))[pk] || null, [KEYD, PIN])
  const near = (a, s) => a && Math.abs(a.lat - s.lat) < 1e-6 && Math.abs(a.lng - s.lng) < 1e-6

  await box.evaluate((e) => e.scrollIntoView({ block: 'start' })); await p.evaluate(() => window.scrollBy(0, -16)); await sleep(200)
  const closed = await state(), top0 = await mapTop()
  ok(closed.role === 'combobox' && closed.exp === 'false' && closed.listRole === 'listbox' && closed.ctl && closed.ctl === closed.listId, `${name}: the box is a combobox (aria-expanded false) controlling the listbox`, { role: closed.role, exp: closed.exp, ctl: closed.ctl, listId: closed.listId, listRole: closed.listRole })
  await openList()
  const st = await state(), top1 = await mapTop(), n = st.rows.length
  await p.screenshot({ path: `${out}/${name}_open.png` })
  ok(n === 5, `${name}: at most five suggestions (the stub offers six)`, n)
  ok(st.listPos === 'absolute', `${name}: the list is positioned absolutely`, st.listPos)
  ok(Math.abs(top1 - top0) < 0.5, `${name}: the map does not move when the list opens`, { before: top0, after: top1 })
  ok(n && Math.abs(st.list.top - st.inp.bottom) <= 1 && Math.abs(st.list.left - st.inp.left) <= 1 && Math.abs(st.list.width - st.inp.width) <= 1, `${name}: one panel directly under the box, as wide as the box`, { inp: [st.inp.left, st.inp.bottom, st.inp.width], list: [st.list.left, st.list.top, st.list.width] })
  ok(st.rbl === '0px' && st.rbr === '0px' && closed.rbl !== '0px', `${name}: the box's bottom corners square off only while the list is open`, { closed: closed.rbl, open: [st.rbl, st.rbr] })
  const hs = st.rows.map((r) => Math.round(r.h * 10) / 10)
  ok(n && (touch ? hs.every((x) => x >= 44) : hs.every((x) => x >= 40 && x <= 48)), `${name}: rows ${touch ? 'at least 44px (touch)' : 'about 44px (mouse)'}`, hs)
  const mWant = pc ? '14px/600' : '16px/600'
  ok(n && st.rows.every((r) => r.m === mWant && /^13px rgb\(82, 82, 91\)$/.test(r.s)), `${name}: street ${mWant}, city 13px grey`, st.rows[0])
  ok(st.exp === 'true' && st.rows.every((r) => r.role === 'option' && r.sel === 'false' && r.id) && !st.ad, `${name}: open: aria-expanded true, rows are options, none selected yet`, { exp: st.exp, rows: st.rows.map((r) => [r.role, r.sel, r.id]).slice(0, 2), ad: st.ad })
  ok(st.rows.every((r) => r.bg === WHITE), `${name}: no row is highlighted before a key or the mouse moves`, st.rows.map((r) => r.bg))
  ok(st.focused, `${name}: the box keeps the focus while the list is open`)
  // the list paints above the map (elementFromPoint in the list, over the map's area) and below the sticky Submit bar
  const paint = await p.evaluate(() => {
    const q = [...document.querySelectorAll('.q')].find((e) => /Truck parking spot/.test(e.textContent)), list = q.querySelector('.alist'), map = q.querySelector('.map')
    const L = list.getBoundingClientRect(), M = map.getBoundingClientRect(), y = Math.max(L.top, M.top) + 8, x = L.left + L.width / 2
    const hit = document.elementFromPoint(x, y)
    return { overlapsMap: L.bottom > M.top, onList: !!(hit && hit.closest && hit.closest('.alist')), hit: hit && (hit.className || hit.tagName) }
  })
  ok(paint.overlapsMap && paint.onList, `${name}: the list covers the map and paints above it${REAL ? ' (the real Google map)' : ''}`, paint)
  if (touch) { // push the box down so the list runs under the sticky bar: the bar stays on top (600px tall, so the page
    // can scroll that far at every width; above 500px the bar is still sticky)
    await p.setViewportSize({ width: w, height: 600 }); await sleep(150)
    await box.evaluate((e) => { const f = document.getElementById('foot').getBoundingClientRect(); window.scrollBy(0, e.getBoundingClientRect().bottom - (f.top - 60)) }); await sleep(250)
    const under = await p.evaluate(() => { const f = document.getElementById('foot'), fr = f.getBoundingClientRect(), L = document.querySelector('.q .alist').getBoundingClientRect(); const x = L.left + L.width / 2, y = fr.top + 10; const hit = document.elementFromPoint(x, y); return { listUnderBar: L.bottom > fr.top + 10, barOnTop: !!(hit && f.contains(hit)), hit: hit && (hit.id || hit.className || hit.tagName) } })
    ok(under.listUnderBar && under.barOnTop, `${name}: the sticky Submit bar stays above the list`, under)
    await p.setViewportSize({ width: w, height: h }); await sleep(150)
    await box.evaluate((e) => e.scrollIntoView({ block: 'start' })); await p.evaluate(() => window.scrollBy(0, -16)); await sleep(200)
  }
  // keyboard: ArrowDown highlights the first row, again the second; ArrowUp from none goes to the last
  await box.press('ArrowDown'); await box.press('ArrowDown'); await sleep(100)
  const k2 = await state()
  const one = (s, i) => s.rows.length && s.rows.every((r, j) => (j === i ? r.bg === ORT && r.sel === 'true' : r.bg === WHITE && r.sel === 'false')) && s.ad === s.rows[i].id
  ok(one(k2, 1), `${name}: ArrowDown twice highlights row 2 in #fff4ef (aria-selected, aria-activedescendant)`, { bg: k2.rows.map((r) => r.bg), sel: k2.rows.map((r) => r.sel), ad: k2.ad })
  ok(k2.focused && (await box.inputValue()) === '650 NW 33rd St', `${name}: arrows keep the focus and the typed text in the box`)
  await box.press('Enter'); await sleep(400)
  const a1 = await pin(), s1 = await state(), rec1 = await p.evaluate(() => ({ pans: window.__pans.slice(-1)[0], zooms: window.__zooms.slice(-1)[0] }))
  ok(near(a1, SUGG[1]) && a1.accuracy_m === undefined && s1.rows.length === 0 && s1.exp === 'false' && /Pin placed at that address/.test(s1.hint), `${name}: Enter takes the HIGHLIGHTED row: the pin goes there and the list closes`, { a1, want: SUGG[1], hint: s1.hint, exp: s1.exp })
  ok(near(rec1.pans, SUGG[1]) && rec1.zooms === 20 && /Oakland Park/.test(await box.inputValue()), `${name}: ... and the map pans there at zoom 20, the box shows the address`, { rec1, v: await box.inputValue() })
  await openList(); await box.press('ArrowUp'); await sleep(100)
  ok(one(await state(), 4), `${name}: ArrowUp with nothing highlighted goes to the last row`)
  await box.press('ArrowDown'); await sleep(80)
  ok(one(await state(), 0), `${name}: ArrowDown from the last row wraps to the first`)
  await box.press('Escape'); await sleep(200)
  const e1 = await state()
  ok(e1.rows.length === 0 && e1.exp === 'false' && !e1.ad && (await box.inputValue()) === '650 NW 33rd St', `${name}: Escape closes the list and keeps the text`, { rows: e1.rows.length, exp: e1.exp, ad: e1.ad })
  // Enter with nothing highlighted keeps today's behaviour: the first row
  await openList(); await box.press('Enter'); await sleep(400)
  ok(near(await pin(), SUGG[0]), `${name}: Enter with nothing highlighted takes the first row (as before)`, await pin())
  // the mouse highlights the row under it (mouse contexts only)
  if (!touch) {
    await openList(); const r3 = await card.locator('.asug').nth(2).boundingBox(); await p.mouse.move(r3.x + r3.width / 2, r3.y + r3.height / 2); await sleep(150)
    ok(one(await state(), 2), `${name}: the row under the mouse is highlighted in #fff4ef (one row only)`, (await state()).rows.map((r) => r.bg))
    await p.screenshot({ path: `${out}/${name}_hover.png` })
    await box.press('Escape'); await sleep(150)
  }
  // a tap or a click on a row still does what it did: the pin goes to that address
  await openList(); await tap(card.locator('.asug').nth(3)); await sleep(500)
  const a4 = await pin(), s4 = await state()
  ok(near(a4, SUGG[3]) && s4.rows.length === 0 && /Pin placed at that address/.test(s4.hint) && /Doral/.test(await box.inputValue()), `${name}: a ${touch ? 'tap' : 'click'} on a row puts the pin at that address and closes the list`, { a4, want: SUGG[3], hint: s4.hint })
  // a tap outside the box closes the list; a search still waiting is cancelled (nothing reopens it)
  await openList(); const lab = card.locator('label').first(); await tap(lab); await sleep(250)
  const o1 = await state()
  ok(o1.rows.length === 0 && o1.exp === 'false' && !o1.focused, `${name}: a tap outside closes the list`, { rows: o1.rows.length, exp: o1.exp, focused: o1.focused })
  const pl0 = await p.evaluate(() => window.__places)
  await box.click(); await box.fill('1745 Cleveland Road'); await tap(lab); await sleep(900)
  const o2 = await state(), pl1 = await p.evaluate(() => window.__places)
  ok(o2.rows.length === 0 && pl1 === pl0, `${name}: a tap outside before the search runs cancels it (no search, nothing reopens)`, { rows: o2.rows.length, searches: pl1 - pl0 })
  // clearing the box closes the list
  await openList(); await box.fill(''); await sleep(200)
  const c1 = await state()
  ok(c1.rows.length === 0 && c1.exp === 'false', `${name}: clearing the box closes the list`)
  ok(!c1.overflowX, `${name}: no sideways scroll`)
  const gPlaces = google.filter((u) => /places/.test(u)).length + placesNet.length
  ok(gPlaces === 0 && (await p.evaluate(() => window.__places)) > 0, `${name}: Places is the stub: ${await p.evaluate(() => window.__places)} searches, 0 Places requests to Google`, { placesNet: placesNet.length })
  ok(S.ops.every((o) => o === 'load') && S.errors.length === 0, `${name}: only the load call reached the (fake) backend, no page error`, { ops: S.ops, errors: S.errors.slice(0, 3) })
  await p.evaluate(() => localStorage.clear())
  await browser.close()
}
console.log(`\n${pass} passed, ${fail} failed${REAL ? ' (REAL_MAP)' : ''}  [${process.env.INTAKE_HTML ? 'INTAKE_HTML=' + process.env.INTAKE_HTML.split(/[\\/]/).pop() : 'intake.html'}]`)
if (fail) process.exitCode = 1
